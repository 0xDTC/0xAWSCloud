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

STOP_ALL       = threading.Event()          # master “please stop” flag
SPIN_STOP      = threading.Event()          # spinner stop flag
LOCK           = threading.Lock()           # console lock
EXECUTORS: list[cf.ThreadPoolExecutor] = [] # keep refs for Ctrl-C cleanup
BASE_FOUND     = threading.Event()          # flag for when the exact base bucket is found

FOUND_BUCKETS  = {}                         # mapping of bucket names to their found regions

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
    
    # If the exact base bucket is found, set the flag to stop other checks
    if bucket and bucket == BASE:
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
    env = ("dev", "staging", "test", "qa", "prod")
    suf = (
        "logs", "backups", "archive", "resources", "files", "images",
        "static", "uploads", "cdn", "content", "assets", "config", "data", "api",
    )
    v: list[str] = [
        b, f"www.{b}", f"{b}-www",
        f"{b}.com", f"www.{b}.com", f"{b}-com", f"www-{b}-com",
    ]
    v += [f"{b}-{e}" for e in env] + [f"{e}-{b}" for e in env]
    v += [f"{b}-{s}" for s in suf] + [f"{s}-{b}" for s in suf]
    v += [
        f"{b}-s3", f"s3-{b}", b.replace("_", "-"), b.replace("-", "_"),
        f"{b}-app", f"app-{b}", f"{b}-service", f"service-{b}",
        f"{b}-storage", f"{b}-dist",
        f"{b}-v1", f"{b}-v2", f"{b}-old", f"{b}-new",
        f"v1-{b}",  f"v2-{b}",
        f"{b}.com-dev",  f"{b}.com-test",  f"{b}.com-prod",
        f"dev-{b}.com",  f"test-{b}.com",  f"prod-{b}.com",
    ]
    dash = b.replace(".", "-")
    v += [dash, f"www-{dash}", f"{dash}-dev", f"{dash}-prod", f"{dash}-logs", f"{dash}-assets"]
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
    _cli_probe(BASE)


# ────────────────────────── web probe
def _fetch(url: str) -> str:
    """Fetch URL content, return the response body as string."""
    req = urllib.request.Request(url, headers={"User-Agent": "Mozilla"})
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.read(4096).decode(errors="ignore")
    except urllib.error.HTTPError as e:
        try:
            return e.read().decode(errors="ignore")
        except Exception as ex:
            return f"Error: {ex}"
    except Exception as ex:
        return f"Error: {ex}"


def _endpoints(b: str, r: str) -> Generator[str, None, None]:
    yield from (
        b,
        f"{b}.s3.amazonaws.com",
        f"s3.amazonaws.com/{b}",
        f"{b}.s3.{r}.amazonaws.com",
        f"{b}.s3-website.{r}.amazonaws.com",
        f"{b}.s3-website-{r}.amazonaws.com",
        f"{b}.s3-{r}.amazonaws.com",
        f"s3.{r}.amazonaws.com/{b}",
        f"s3-website.{r}.amazonaws.com/{b}",
        f"s3-website-{r}.amazonaws.com/{b}",
        f"s3-{r}.amazonaws.com/{b}",
        f"{b}.s3.dualstack.{r}.amazonaws.com",
        f"s3.dualstack.{r}.amazonaws.com/{b}",
    )


def _web_check(url: str) -> None:
    """Check a single URL for accessibility, log results."""
    if url in CHECKED_SET or STOP_ALL.is_set() or BASE_FOUND.is_set():
        return
    CHECKED_SET.add(url)
    try:
        # Extract bucket name and region from URL
        parts = url.split('//')
        if len(parts) > 1:
            hostname = parts[1].split('/')[0]
            bucket_name = hostname.split('.')[0]
            region = None
            if 's3' in hostname and 'amazonaws.com' in hostname:
                region_part = hostname.split('.')
                if len(region_part) > 2 and region_part[1] != 's3':
                    region = region_part[1]
        else:
            return
            
        # Skip if we've already found this bucket with this region
        region_label = "No Region" if region is None else region
        if bucket_name in FOUND_BUCKETS and (region is None or region_label in FOUND_BUCKETS[bucket_name]):
            return
            
        resp = _fetch(url)
        if re.search(r"<Key>|<Contents>", resp):
            _mark_found(bucket_name, region_label)
            _log(f"\033[1;33m[Web]\033[0m \033[1;32mListable\033[0m: \033[1;36m{url}\033[0m", show_always=True)
        elif re.search(r"(ListBucketResult|CommonPrefixes)", resp):
            _mark_found(bucket_name, region_label)
            _log(f"\033[1;33m[Web]\033[0m \033[1;32mEmpty but listable\033[0m: \033[1;36m{url}\033[0m", show_always=True)
        elif VERBOSE and re.search(r"(AccessDenied|NoSuchBucket|InvalidBucketName)", resp):
            code = _error_code(resp)
            _log(f"\033[1;31m[Web]\033[0m Not accessible: \033[1;36m{url}\033[0m ({code})")
        elif VERBOSE:
            _log(f"\033[1;31m[Web]\033[0m Not listable: \033[1;36m{url}\033[0m")
    except urllib.error.URLError as ex:
        if VERBOSE:
            _log(f"\033[1;31m[Web]\033[0m Error: \033[1;36m{url}\033[0m ({ex.reason})")
    except Exception as ex:
        if VERBOSE:
            _log(f"\033[1;31m[Web]\033[0m Exception: \033[1;36m{url}\033[0m ({ex})")


def _run_web() -> None:
    """Check all variations and permutations of the base bucket name via web.
    This is where we try different name variations.
    """
    with cf.ThreadPoolExecutor(max_workers=THREADS) as exec:
        EXECUTORS.append(exec)
        futures = []
        for bucket in VARIATIONS:
            for r in REGIONS + [None]:
                region = r or ""
                for url in _endpoints(bucket, region):
                    futures.append(exec.submit(_web_check, url))

        total = len(futures)
        # wait for all http requests to complete
        for i, _ in enumerate(cf.as_completed(futures)):
            if STOP_ALL.is_set():
                break
            if i % 5 == 0 or i+1 == total:  # Update counter more frequently
                _progress_counter(i+1, total)


# ────────────────────────── MAIN
def main() -> None:
    """Show welcome message, start spinner, run tests, show results."""
    if RUN_CLI and not shutil.which("aws"):
        print("\033[1;31mError: AWS CLI not found. Install it or use --web-only flag.\033[0m")
        sys.exit(1)

    mode = "Web-only" if RUN_WEB and not RUN_CLI else "CLI-only" if RUN_CLI and not RUN_WEB else "Both Web and CLI checks"
    print("==== S3 Bucket Accessibility Check ====")
    print(f"Base name: {BASE}")
    print(f"Mode: {mode}")
    if VERBOSE:
        print("Verbose mode: ON (showing all attempts)")

    # No spinner thread needed with progress counter

    try:
        # CLI check - only checks the exact base bucket in different regions
        if RUN_CLI:
            _run_cli()
        
        # Web checks - checks name variations and permutations
        if RUN_WEB:
            _run_web()
    except KeyboardInterrupt:
        print("\n\033[1;33mSearch interrupted by user.\033[0m")
    finally:
        # Clear the progress counter line
        sys.stdout.write("\r" + " " * 50 + "\r")
        sys.stdout.flush()
        
        # Print summary of found buckets
        if BASE in FOUND_BUCKETS:
            print(f"\n\033[1;32mBase bucket '{BASE}' is accessible!\033[0m")
        else:
            print(f"\n\033[1;33mFound {len(FOUND_BUCKETS)} accessible bucket(s), but not the base bucket '{BASE}'.\033[0m")
        
        if not FOUND_BUCKETS:
            print("\033[1;31mNo accessible buckets found.\033[0m")

if __name__ == "__main__":
    main()