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
import shutil
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
import urllib.error
import urllib.request
from pathlib import Path
from typing import Generator
from types import FrameType
import ssl

# ────────────────────────── CLI flags
PAR = argparse.ArgumentParser(description="S3 bucket accessibility checker")
PAR.add_argument("-b", "--bucket", required=True, help="Base bucket name")
MEX = PAR.add_mutually_exclusive_group()
MEX.add_argument("-w", "--web-only", action="store_true", help="Web checks only")
MEX.add_argument("-c", "--cli-only", action="store_true", help="CLI checks only")
PAR.add_argument("-v", "--verbose", action="store_true", help="Show all access attempts (verbose mode)")
PAR.add_argument("-t", "--threads", type=int, default=30, help="Concurrent threads for web checks (default: 30)")
ARGS = PAR.parse_args()

BASE: str = ARGS.bucket.strip()
RUN_WEB: bool = not ARGS.cli_only
RUN_CLI: bool = not ARGS.web_only
VERBOSE: bool = ARGS.verbose
THREADS: int = ARGS.threads

# Remove user-facing insecure flag; always skip certificate verification for HTTPS.
# Create SSL context once.
SSL_CONTEXT = ssl.create_default_context()
SSL_CONTEXT.check_hostname = False
SSL_CONTEXT.verify_mode = ssl.CERT_NONE

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
FOUND_BUCKETS: dict[str, set[str]] = {}        # mapping of bucket names to their found regions
CLI_MODE_DONE  = threading.Event()          # flag to indicate CLI checks are complete

# ────────────────────────── test file constants
TEST_FILENAME = "Bug-Bounty-From-Production-Exploiter.txt"

# User-provided message (will be set at runtime)
TEST_CONTENT = ""

# Whether to attempt DELETE after PUT
TEST_DELETE: bool = True

# Local path for the temporary test file
TEST_FILE_PATH = TDIR / TEST_FILENAME

# Helper: (re)create local test file
def _ensure_test_file() -> Path:
    try:
        TEST_FILE_PATH.write_text(TEST_CONTENT, encoding="utf-8")
    except Exception:
        pass
    return TEST_FILE_PATH

# Get user message and options for test actions
def _get_test_params() -> None:
    global TEST_CONTENT, TEST_DELETE
    if TEST_CONTENT:  # Already gathered
        return

    # Prompt for custom message
    print("Enter the message to put in your test file (cannot be empty):")
    while not TEST_CONTENT:
        user_input = input("> ").strip()
        if user_input:
            TEST_CONTENT = user_input
        else:
            print("Message cannot be empty. Please enter a message:")

    # Prompt for PUT-only or PUT+DELETE
    choice = input("Do you want to test ONLY PUT (skip DELETE)? [y/N]: ").strip().lower()
    if choice in ("y", "yes"):
        TEST_DELETE = False
        print("Will perform PUT checks only (no DELETE).\n")
    else:
        TEST_DELETE = True
        print("Will perform both PUT and DELETE checks.\n")

    print(f"Using test message: '{TEST_CONTENT}'\n")

# ────────────────────────── graceful shutdown
def _cleanup(_sig: int | None = None, _frame: FrameType | None = None) -> None:
    STOP_ALL.set()
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
    if CHECKED_SET:
        try:
            Path(TDIR / "checked_urls").write_text("\n".join(sorted(CHECKED_SET)))
        except Exception:
            pass
    os._exit(130 if _sig in (signal.SIGINT, signal.SIGTERM) else 0)

signal.signal(signal.SIGINT, _cleanup)
signal.signal(signal.SIGTERM, _cleanup)

# ────────────────────────── console helpers
def _log(msg: str, show_always: bool = False) -> None:
    if show_always or VERBOSE:
        with LOCK:
            sys.stdout.write("\r" + " " * 80 + "\r")
            print(msg, flush=True)


def _progress_counter(current: int, total: int) -> None:
    with LOCK:
        sys.stdout.write("\r" + " " * 80 + "\r")
        sys.stdout.write(f"[{current}/{total}] Checking...")
        sys.stdout.flush()


def _mark_found(bucket: str | None = None, region: str | None = None) -> None:
    FOUND_FLAG.touch()
    if bucket:
        with LOCK:
            FOUND_BUCKETS.setdefault(bucket, set())
            if region:
                FOUND_BUCKETS[bucket].add(region)
    if bucket == BASE and not BASE_FOUND.is_set():
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
    if (m := ERR_IN_PAREN.search(text)):
        return m.group(1)
    if "Traceback (most recent call last):" in text:
        return "Traceback"
    for word in ("AccessDenied","NoSuchBucket","InvalidBucketName"):
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
                # Perform PUT / DELETE checks via AWS CLI
                _ensure_test_file()
                put_ok = False
                del_ok = False
                cp_cmd = [
                    "aws", "s3", "cp", str(TEST_FILE_PATH),
                    f"s3://{bucket}/{TEST_FILENAME}", "--no-sign-request"
                ]
                rm_cmd = [
                    "aws", "s3", "rm",
                    f"s3://{bucket}/{TEST_FILENAME}", "--no-sign-request"
                ]
                if region:
                    cp_cmd += ["--region", region]
                    rm_cmd += ["--region", region]
                try:
                    subprocess.check_output(cp_cmd, stderr=subprocess.STDOUT, text=True)
                    put_ok = True
                except subprocess.CalledProcessError:
                    pass

                if TEST_DELETE and put_ok:
                    try:
                        subprocess.check_output(rm_cmd, stderr=subprocess.STDOUT, text=True)
                        del_ok = True
                    except subprocess.CalledProcessError:
                        pass
                flag_parts: list[str] = []
                if put_ok: flag_parts.append("PUT")
                if del_ok: flag_parts.append("DELETE")
                flags = f" ({', '.join(flag_parts)})" if flag_parts else ""

                _mark_found(bucket, label)
                _log(
                    f"\033[1;33m[AWS CLI]\033[0m Found: "
                    f"\033[1;32ms3://{bucket}\033[0m {label} "
                    f"\033[0;36m(objects: {m.group(1)})\033[0m{flags}",
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
def _fetch(url: str) -> tuple[int, str, dict[str, str]]:
    ctx = SSL_CONTEXT if url.startswith("https://") else None
    try:
        with urllib.request.urlopen(urllib.request.Request(url), context=ctx) as resp:
            return resp.status, resp.read().decode(errors="ignore"), dict(resp.getheaders())
    except urllib.error.HTTPError as e:
        try: 
            body = e.read().decode(errors="ignore")
        except Exception as _:
            body = ""
        return e.code, body, dict(e.headers or {}) if e.headers else {}
    except Exception as e:
        return 0, str(e), {}  # Empty dict[str, str]


def _endpoints(bucket: str, region: str | None) -> Generator[str, None, None]:
    for proto in ("http", "https"):
        yield f"{proto}://{bucket}"
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
    with LOCK:
        if url in CHECKED_SET or STOP_ALL.is_set(): return
        CHECKED_SET.add(url)
    status, body, _ = _fetch(url)
    found = False
    label = ""
    if status == 403 and 'AccessDenied' in body and not any(x in body for x in ('NoSuchBucket','InvalidBucketName')):
        found = True
        label = "Found (Access Denied)"
    elif status == 200 and '<ListBucketResult xmlns=' in body and not any(e in body for e in ("NoSuchBucket","InvalidBucketName")):
        found = True
        label = "Accessible"
    if found:
        _mark_found(BASE, None)  # type: ignore
        if url.startswith("https://"): color = "\033[1;32m"
        elif url.startswith("http://"): color = "\033[1;31m"
        else: color = "\033[0m"

        # Perform PUT / DELETE checks only when bucket listing accessible (label == "Accessible")
        put_ok = False
        del_ok = False
        if label == "Accessible":
            object_url = url.rstrip("/") + "/" + TEST_FILENAME
            # PUT request
            try:
                req_put = urllib.request.Request(
                    object_url,
                    data=TEST_CONTENT.encode(),
                    method="PUT",
                    headers={"Content-Type": "text/plain"},
                )
                with urllib.request.urlopen(req_put, context=SSL_CONTEXT if object_url.startswith("https://") else None) as resp:
                    if resp.status in (200, 201, 204):
                        put_ok = True
            except Exception:
                pass
            # DELETE request only if configured
            if TEST_DELETE and put_ok:
                try:
                    req_del = urllib.request.Request(object_url, method="DELETE")
                    with urllib.request.urlopen(req_del, context=SSL_CONTEXT if object_url.startswith("https://") else None) as resp:
                        if resp.status in (200, 204):
                            del_ok = True
                except Exception:
                    pass
        flag_parts: list[str] = []
        if put_ok: flag_parts.append("PUT")
        if del_ok: flag_parts.append("DELETE")
        flags = f" ({', '.join(flag_parts)})" if flag_parts else ""

        # Print directly while safely clearing current progress line.
        with LOCK:
            sys.stdout.write("\r" + " " * 80 + "\r")
            print(f"[Web] {label}: {color}{url}\033[0m{flags}", flush=True)
    elif VERBOSE:
        _log(f"[Web] Not listable: {url}")


def _run_web() -> None:
    print(f"Checking web endpoints for '{BASE}'...")
    all_urls: list[str] = []
    for b in [BASE] + [v for v in VARIATIONS if v != BASE]:
        all_urls.extend(list(_endpoints(b, '')))
        for r in REGIONS:
            all_urls.extend(list(_endpoints(b, r)))
    total = len(all_urls)
    # Note: Don't reorder list; order affects early discovery speed.
    done = 0
    with cf.ThreadPoolExecutor(max_workers=THREADS) as ex:
        EXECUTORS.append(ex)
        futures = [ex.submit(_web_check, url) for url in all_urls]
        for _ in cf.as_completed(futures):
            done += 1
            _progress_counter(done, total)
            if STOP_ALL.is_set(): break
    sys.stdout.write("\r" + " "*80 + "\r")


# ──────────────────── MAIN
if __name__ == '__main__':
    if RUN_CLI and not shutil.which("aws"):
        print("Error: AWS CLI not found. Install or use --web-only.")
        sys.exit(1)
    print("==== S3 Bucket Accessibility Check ====")
    print(f"Base name: {BASE}")
    mode = "Both Web and CLI checks" if RUN_CLI and RUN_WEB else "CLI-only" if RUN_CLI else "Web-only"
    print(f"Mode: {mode}")
    if VERBOSE: print("Verbose mode: ON")
    # Get user message and options for test actions
    _get_test_params()
    try:
        if RUN_CLI: _run_cli()
        if RUN_WEB: _run_web()
    except KeyboardInterrupt:
        print("\nSearch interrupted by user.")
    finally:
        if BASE in FOUND_BUCKETS:
            print(f"\nBase bucket '{BASE}' is accessible!")
        else:
            print(f"\nFound {len(FOUND_BUCKETS)} accessible bucket(s), but not the base bucket '{BASE}'.")
        if not FOUND_BUCKETS:
            print("No accessible buckets found.")