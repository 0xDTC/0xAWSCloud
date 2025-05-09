#!/usr/bin/env python3
"""
s3_regions.py – scan for publicly-listable S3 buckets derived from a base name.

Usage
─────
  ./s3_regions.py -b examplebucket          # web + CLI (default)
  ./s3_regions.py -b examplebucket -w       # web only
  ./s3_regions.py -b examplebucket -c       # CLI only
"""

from __future__ import annotations

import argparse
import concurrent.futures as cf
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Generator
from types import FrameType

# ────────────────────────── CLI flags
PAR = argparse.ArgumentParser(description="S3 bucket accessibility checker")
PAR.add_argument("-b", "--bucket", required=True, help="Base bucket name")
MEX = PAR.add_mutually_exclusive_group()
MEX.add_argument("-w", "--web-only", action="store_true", help="Web checks only")
MEX.add_argument("-c", "--cli-only", action="store_true", help="CLI checks only")
PAR.add_argument("-v", "--verbose", action="store_true", help="Show all access attempts (verbose mode)")
ARGS = PAR.parse_args()

BASE: str = ARGS.bucket.strip()
RUN_WEB: bool = not ARGS.cli_only
RUN_CLI: bool = not ARGS.web_only
VERBOSE: bool = ARGS.verbose
THREADS: int = 5

# ────────────────────────── tmp-files / shared flags
TDIR           = Path(tempfile.mkdtemp(prefix="s3chk_"))
FOUND_FLAG     = TDIR / "found"
CHECKED_TXT    = TDIR / "checked_urls"
CHECKED_SET: set[str] = set()
PRINTED_URLS: set[str] = set()
STOP_ALL       = threading.Event()          # master “please stop” flag
SPIN_STOP      = threading.Event()          # spinner stop flag
LOCK           = threading.Lock()           # console lock
EXECUTORS: list[cf.ThreadPoolExecutor] = [] # keep refs for Ctrl-C cleanup
BASE_FOUND     = threading.Event()          # flag for when the exact base bucket is found
FOUND_BUCKETS  = {}                         # mapping of bucket names to their found regions
CLI_MODE_DONE  = threading.Event()          # flag to indicate CLI checks are complete

# ────────────────────────── graceful shutdown
def _cleanup(_sig: int | None = None, _frame: FrameType | None = None) -> None:  # noqa: D401
    """Kill executors, stop spinner, remove tmpdir, leave immediately."""
    STOP_ALL.set()
    SPIN_STOP.set()

    for ex in EXECUTORS:
        try:
            ex.shutdown(wait=False, cancel_futures=True)
        except Exception:
            pass

    try:
        if TDIR.exists():
            TDIR.rmdir()
    except Exception:
        pass

    # write checked-set once (debugging / later runs)
    if CHECKED_SET:
        try:
            CHECKED_TXT.write_text("".join(s + "\n" for s in sorted(CHECKED_SET)))
        except Exception:
            pass

    os._exit(130 if _sig in (signal.SIGINT, signal.SIGTERM) else 0)  # noqa: WPS421


signal.signal(signal.SIGINT, _cleanup)
signal.signal(signal.SIGTERM, _cleanup)

# ────────────────────────── console helpers
def _log(msg: str, show_always: bool = False) -> None:
    """Print *msg* without colliding with progress counter.
    Only prints if show_always is True (for found buckets) or if verbose mode.
    """
    if show_always or VERBOSE:
        with LOCK:
            sys.stdout.write("\r" + " " * 80 + "\r")
            print(msg, flush=True)


def _progress_counter(current: int, total: int) -> None:
    """Show a progress counter in a simple format"""
    with LOCK:
        sys.stdout.write(f"\r[{current}/{total}] Checking..." + " " * 20)
        sys.stdout.flush()


def _mark_found(bucket: str = None, region: str = None) -> None:
    FOUND_FLAG.touch()
    # Update found buckets dictionary
    if bucket:
        with LOCK:
            if bucket not in FOUND_BUCKETS:
                FOUND_BUCKETS[bucket] = set()
            if region:
                FOUND_BUCKETS[bucket].add(region)
    
    # Only set the BASE_FOUND flag to stop current check type
    # But allow web checks to still run after CLI checks
    if bucket and bucket == BASE and not BASE_FOUND.is_set():
        BASE_FOUND.set()


# ────────────────────────── regions & name variations
REGIONS = [
    "us-east-1",  "us-east-2",  "us-west-1",  "us-west-2",
    "af-south-1", "ap-east-1",  "ap-southeast-1", "ap-southeast-2",
    "ap-southeast-3", "ap-northeast-1", "ap-northeast-2", "ap-northeast-3",
    "ap-south-1", "ca-central-1",
    "cn-north-1", "cn-northwest-1",
    "eu-central-1", "eu-west-1", "eu-west-2", "eu-west-3",
    "eu-north-1", "eu-south-1",
    "me-south-1", "me-central-1",
    "sa-east-1",
    "us-gov-east-1", "us-gov-west-1",
    "us-iso-east-1", "us-iso-west-1", "us-isob-east-1",
]


def _variations(b: str) -> list[str]:
    """Generate comprehensive bucket name variations for testing.
    Based on the shell script's variations list.
    """
    v: list[str] = [
        b,
        f"www.{b}",
        f"{b}-www",
        f"{b}.com",
        f"www.{b}.com",
        f"{b}-com",
        f"www-{b}-com",
        f"{b}-dev",
        f"{b}-staging",
        f"{b}-test",
        f"{b}-qa",
        f"{b}-prod",
        f"dev-{b}",
        f"staging-{b}",
        f"test-{b}",
        f"qa-{b}",
        f"prod-{b}",
        f"{b}-logs",
        f"{b}-backups",
        f"{b}-archive",
        f"{b}-resources",
        f"{b}-files",
        f"{b}-images",
        f"{b}-static",
        f"{b}-uploads",
        f"{b}-cdn",
        f"{b}-content",
        f"{b}-assets",
        f"{b}-config",
        f"{b}-data",
        f"{b}-api",
        f"cdn-{b}",
        f"files-{b}",
        f"uploads-{b}",
        f"static-{b}",
        f"assets-{b}",
        f"logs-{b}",
        f"backups-{b}",
        f"archive-{b}",
        f"resources-{b}",
        f"s1-{b}",
        f"s2-{b}",
        f"s3-{b}",
        f"{b}-s1",
        f"{b}-s2",
        f"{b}-s3",
        f"s3-{b}",
        b.replace('_', '-'),
        b.replace('-', '_'),
        f"{b}-app",
        f"app-{b}",
        f"{b}-service",
        f"service-{b}",
        f"{b}-storage",
        f"{b}-dist",
        f"{b}-v1",
        f"{b}-v2",
        f"{b}-old",
        f"{b}-new",
        f"v1-{b}",
        f"v2-{b}",
        f"{b}.com-dev",
        f"{b}.com-test",
        f"{b}.com-prod",
        f"dev-{b}.com",
        f"test-{b}.com",
        f"prod-{b}.com",
        b.replace('.', '-'),
        f"www-{b.replace('.', '-')}",
        f"{b.replace('.', '-')}-dev",
        f"{b.replace('.', '-')}-prod",
        f"{b.replace('.', '-')}-logs",
        f"{b.replace('.', '-')}-assets"
    ]
    # Remove duplicates while preserving order
    return list(dict.fromkeys(v))


VARIATIONS = _variations(BASE)

# ────────────────────────── AWS-CLI probe
TOTAL_RE = re.compile(r"Total\s+Objects:\s+(\d+)")
ERR_IN_PAREN = re.compile(r"\(([^)]+)\)")


def _error_code(text: str) -> str:
    """Return a short error token for log output."""
    if (m := ERR_IN_PAREN.search(text)):
        return m.group(1)
    if "Traceback (most recent call last):" in text:
        return "Traceback"
    for word in ("AccessDenied", "NoSuchBucket", "InvalidBucketName"):
        if word in text:
            return word
    return "Error"


def _cli_probe(bucket: str) -> None:
    """Check a single bucket across all AWS regions.
    Only checks the exact bucket name, no variations.
    """
    if STOP_ALL.is_set():
        return
    
    # Only process if this is the exact base bucket
    if bucket != BASE:
        return
        
    total_regions = len(REGIONS) + 1  # +1 for the None region
    
    for i, region in enumerate([None] + REGIONS):
        if STOP_ALL.is_set():
            return
        
        # Update the counter
        _progress_counter(i+1, total_regions)
        
        # Skip if we've already found this bucket with this region
        if bucket in FOUND_BUCKETS and (region is None or region in FOUND_BUCKETS[bucket]):
            continue
            
        label = "No Region" if region is None else region
        cmd = ["aws", "s3", "ls", f"s3://{bucket}", "--no-sign-request", "--summarize"]
        if region:
            cmd += ["--region", region]

        try:
            out = subprocess.check_output(cmd, text=True, stderr=subprocess.STDOUT)
            if (m := TOTAL_RE.search(out)):
                _mark_found(bucket, label)
                _log(
                    f"\033[1;33m[AWS CLI]\033[0m Found: "
                    f"\033[1;32ms3://{bucket}\033[0m {label} "
                    f"\033[0;36m(objects: {m.group(1)})\033[0m",
                    show_always=True
                )
        except subprocess.CalledProcessError as exc:
            # Always log errors on failed ls attempts
                code = _error_code(exc.output)
                _log(
                    f"\033[1;31m[AWS CLI]\033[0m Not accessible: "
                    f"\033[1;32ms3://{bucket}\033[0m {label} ({code})",
                    show_always=True
                )


def _run_cli() -> None:
    """Only probe the exact BASE bucket across every region.
    No name variations are checked in CLI mode.
    """
    # Reset CLI_MODE_DONE flag
    CLI_MODE_DONE.clear()
    
    # Run CLI checks
    _cli_probe(BASE)
    
    # Set flag to indicate CLI checks are done
    CLI_MODE_DONE.set()


# ────────────────────────── web probe
def _fetch(url: str) -> tuple[int, str, dict]:
    try:
        # Add proper headers to mimic a browser request
        headers = {"User-Agent": "Mozilla/5.0", "Accept": "text/html,application/xhtml+xml"}
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.status, resp.read().decode(errors="ignore"), dict(resp.getheaders())
    except urllib.error.HTTPError as e:
        try:
            body = e.read().decode(errors="ignore")
        except:
            body = ""
        return e.code, body, dict(e.headers or {})
    except Exception as e:
        return 0, str(e), {}

def _endpoints(bucket: str, region: str) -> Generator[str, None, None]:
    # Try the bucket name directly
    yield f"http://{bucket}"
    yield f"https://{bucket}"
    
    for proto in ("http", "https"):
        if not region:
            # Standard global endpoints
            yield f"{proto}://{bucket}.s3.amazonaws.com"
            yield f"{proto}://s3.amazonaws.com/{bucket}"
        else:
            # Standard regional endpoints
            yield f"{proto}://{bucket}.s3.{region}.amazonaws.com"
            yield f"{proto}://s3.{region}.amazonaws.com/{bucket}"

            # Hyphenated regional endpoints
            yield f"{proto}://{bucket}.s3-{region}.amazonaws.com"
            yield f"{proto}://s3-{region}.amazonaws.com/{bucket}"
            yield f"{proto}://{bucket}.s3-website.{region}.amazonaws.com"
            yield f"{proto}://s3-website.{region}.amazonaws.com/{bucket}"
            yield f"{proto}://s3-website-{region}.amazonaws.com/{bucket}"
            yield f"{proto}://{bucket}.s3-website-{region}.amazonaws.com"
            
            # Dualstack endpoints
            yield f"{proto}://{bucket}.s3.dualstack.{region}.amazonaws.com"
            yield f"{proto}://s3.dualstack.{region}.amazonaws.com/{bucket}"

def _web_check(url: str) -> None:
    # Skip if already checked or if we should stop
    with LOCK:
        if url in CHECKED_SET or STOP_ALL.is_set():
            return
        CHECKED_SET.add(url)

    # Skip website endpoints
    if 's3-website' in url:
        return

    # The bucket name is always our base bucket when we're checking pre-defined URLs
    bucket_name = BASE
    
    # Extract region if present in URL for better logging
    region = None
    if '.s3.' in url:
        if '.s3.amazonaws.com' in url:
            region = None  # Global endpoint
        elif '.dualstack.' in url:
            # Extract region from dualstack URL
            match = re.search(r'\.s3\.dualstack\.([\w-]+)\.amazonaws\.com', url)
            if match:
                region = match.group(1)
        else:
            # Extract region from standard URL
            match = re.search(r'\.s3\.([\w-]+)\.amazonaws\.com', url)
            if match:
                region = match.group(1)
    elif '.s3-' in url:
        # Extract region from hyphenated URL
        match = re.search(r'\.s3-([\w-]+)\.amazonaws\.com', url)
        if match:
            region = match.group(1)
    
    region_label = region or 'No Region'
    
    # Skip if we've already found this bucket in this region
    if bucket_name in FOUND_BUCKETS and region_label in FOUND_BUCKETS[bucket_name]:
        return

    try:
        status, body, _ = _fetch(url)
    except Exception as e:
        if VERBOSE:
            _log(f"\033[1;31m[Web]\033[0m Error: {url} ({e})")
        return

    found = False
    msg = ''
    if status == 403 and 'AccessDenied' in body and not any(x in body for x in ('NoSuchBucket','InvalidBucketName')):
        msg = f"\033[1;33m[Web]\033[0m Found (Access Denied): \033[1;33m{url}\033[0m"
        found = True
    elif status == 200:
        # Check for error indicators in 200 responses (as they might be error pages)
        error_indicators = ["<Error>", "WebsiteRedirect", "NoSuchBucket", 
                           "Request does not contain a bucket name", "301 Moved Permanently", 
                           "404 Not Found", "PermanentRedirect", "TemporaryRedirect"]
        
        if not any(indicator in body for indicator in error_indicators):
            # Check for S3 bucket listing indicators
            if "<ListBucketResult xmlns=" in body:
                # Final check to exclude masked errors
                if not any(x in body for x in ["The specified bucket does not exist", "InvalidBucketName"]):
                    msg = f"Accessible: {url}"
                    found = True

    if found:
        _mark_found(bucket_name, region_label)
        
        # Color HTTP URLs red and HTTPS URLs green for accessible buckets
        if "https://" in url:
            url_color = "\033[1;32m"  # Green for HTTPS (secure)
        else:
            url_color = "\033[1;31m"  # Red for HTTP (not secure)
        
        # Format message based on access type
        if status == 403:  # Access Denied
            formatted_msg = f"\033[1;33m[Web]\033[0m Found (Access Denied): {url_color}{url}\033[0m"
        else:  # Accessible
            formatted_msg = f"\033[1;32m[Web]\033[0m Accessible: {url_color}{url}\033[0m"
        
        # Use PRINTED_URLS to track which URLs we've already printed to avoid duplicates
        with LOCK:
            if url not in PRINTED_URLS:
                PRINTED_URLS.add(url)
                print(formatted_msg)
    elif VERBOSE:
        _log(f"\033[1;31m[Web]\033[0m Not listable: {url}")


def _run_web() -> None:
    print(f"Checking web endpoints for '{BASE}'...")
    buckets = [BASE] + [v for v in VARIATIONS if v != BASE]
    
    # Calculate total beforehand by actually counting all the URLs
    all_urls = []
    for b in buckets:
        for url in _endpoints(b, ''):
            all_urls.append(url)
        for r in REGIONS:
            for url in _endpoints(b, r):
                all_urls.append(url)
    
    total = len(all_urls)
    done = 0
    
    # Use progress counter during execution
    with cf.ThreadPoolExecutor(max_workers=THREADS) as ex:
        EXECUTORS.append(ex)
        futures = []
        
        # Submit all URLs for checking
        for url in all_urls:
            futures.append(ex.submit(_web_check, url))
        
        # Process results and update counter
        for _ in cf.as_completed(futures):
            done += 1
            if done % 10 == 0 or done == total:
                _progress_counter(done, total)
            if STOP_ALL.is_set():
                break
    
    sys.stdout.write("\r" + " " * 80 + "\r")
    sys.stdout.flush()


# ──────────────────── MAIN
def main() -> None:
    # Import regex module at runtime
    global re
    import re

    if RUN_CLI and not shutil.which("aws"):
        print("\033[1;31mError: AWS CLI not found. Install or use --web-only.\033[0m")
        sys.exit(1)

    print("==== S3 Bucket Accessibility Check ====")
    print(f"Base name: {BASE}")
    mode = "Web-only" if RUN_WEB and not RUN_CLI else "CLI-only" if RUN_CLI and not RUN_WEB else "Both Web and CLI checks"
    print(f"Mode: {mode}")
    if VERBOSE:
        print("Verbose mode: ON")

    try:
        if RUN_CLI:
            _run_cli()
            sys.stdout.write("\r" + " " * 50 + "\r")
        if RUN_WEB:
            _run_web()
    except KeyboardInterrupt:
        print("\n\033[1;33mSearch interrupted by user.\033[0m")
    finally:
        sys.stdout.write("\r" + " " * 50 + "\r")
        sys.stdout.flush()
        if BASE in FOUND_BUCKETS:
            print(f"\n\033[1;32mBase bucket '{BASE}' is accessible!\033[0m")
        else:
            print(f"\n\033[1;33mFound {len(FOUND_BUCKETS)} accessible bucket(s), but not the base bucket '{BASE}'.\033[0m")
        if not FOUND_BUCKETS:
            print("\033[1;31mNo accessible buckets found.\033[0m")

if __name__ == '__main__':
    main()