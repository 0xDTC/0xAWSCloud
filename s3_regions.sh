#!/bin/bash

########################################
# Cleanup function
########################################
cleanup() {
    # Set cleanup flag first (used by background processes)
    CLEANUP_IN_PROGRESS=1
    echo -e "\nCleaning up..." >&2
    
    # Terminate all curl processes spawned by this script
    for pid in $(pgrep -P $$ curl 2>/dev/null); do
        kill -9 $pid 2>/dev/null || true
    done
    
    # Kill all direct child processes
    pkill -P $$ 2>/dev/null || true
    
    # Give processes time to terminate
    sleep 2
    
    # Force kill any remaining processes
    for pid in $(pgrep -P $$ 2>/dev/null); do
        kill -9 $pid 2>/dev/null || true
    done
    
    # Clean up temp directory if it exists
    if [ -n "$tmpdir" ] && [ -d "$tmpdir" ]; then
        rm -rf "$tmpdir" 2>/dev/null || true
    fi
    
    echo "Done." >&2
    # Exit immediately
    exit 0
}

########################################
# Initialize temp dir, markers, flag, and trap
########################################
tmpdir=$(mktemp -d)

# seed marker files so greps/appends never see "no such file"

touch "$tmpdir"/{checked_urls,found_urls,found_any_markers,printed_urls}
CLEANUP_IN_PROGRESS=0

# only trap INT and TERM so normal exit can reach final summary

trap 'cleanup' INT TERM

########################################
# Display usage
########################################
usage() {
echo "Usage: \$0 -b bucket\_name"
echo "  -b    The base bucket name (required)"
exit 1
}

########################################
# Parse Command-Line
########################################
while getopts ":b:" opt; do
case $opt in
b) BASE_NAME=$OPTARG ;;
*) usage ;;
esac
done

if [ -z "$BASE_NAME" ]; then
usage
fi

########################################
# Full AWS region list
########################################
regions=(
  "us-east-1" "us-east-2" "us-west-1" "us-west-2"
  "af-south-1" "ap-east-1" "ap-southeast-1" "ap-southeast-2"
  "ap-southeast-3" "ap-northeast-1" "ap-northeast-2" "ap-northeast-3"
  "ap-south-1" "ca-central-1" "cn-north-1" "cn-northwest-1"
  "eu-central-1" "eu-west-1" "eu-west-2" "eu-west-3"
  "eu-north-1" "eu-south-1" "me-south-1" "me-central-1"
  "sa-east-1" "us-gov-east-1" "us-gov-west-1" "us-iso-east-1"
  "us-iso-west-1" "us-isob-east-1"
)

########################################
# Big list of bucket name variations
########################################
bucket_variations=(
  "$BASE_NAME"
  "www.$BASE_NAME"
  "$BASE_NAME-www"
  "$BASE_NAME.com"
  "www.$BASE_NAME.com"
  "$BASE_NAME-com"
  "www-$BASE_NAME-com"
  "$BASE_NAME-dev"
  "$BASE_NAME-staging"
  "$BASE_NAME-test"
  "$BASE_NAME-qa"
  "$BASE_NAME-prod"
  "dev-$BASE_NAME"
  "staging-$BASE_NAME"
  "test-$BASE_NAME"
  "qa-$BASE_NAME"
  "prod-$BASE_NAME"
  "$BASE_NAME-logs"
  "$BASE_NAME-backups"
  "$BASE_NAME-archive"
  "$BASE_NAME-resources"
  "$BASE_NAME-files"
  "$BASE_NAME-images"
  "$BASE_NAME-static"
  "$BASE_NAME-uploads"
  "$BASE_NAME-cdn"
  "$BASE_NAME-content"
  "$BASE_NAME-assets"
  "$BASE_NAME-config"
  "$BASE_NAME-data"
  "$BASE_NAME-api"
  "cdn-$BASE_NAME"
  "files-$BASE_NAME"
  "uploads-$BASE_NAME"
  "static-$BASE_NAME"
  "assets-$BASE_NAME"
  "logs-$BASE_NAME"
  "backups-$BASE_NAME"
  "archive-$BASE_NAME"
  "resources-$BASE_NAME"
  "s1-$BASE_NAME"
  "s2-$BASE_NAME"
  "s3-$BASE_NAME"
  "$BASE_NAME-s1"
  "$BASE_NAME-s2"
  "$BASE_NAME-s3"
  "s3-$BASE_NAME"
  "${BASE_NAME/_/-}"
  "${BASE_NAME/-/_}"
  "$BASE_NAME-app"
  "app-$BASE_NAME"
  "$BASE_NAME-service"
  "service-$BASE_NAME"
  "$BASE_NAME-storage"
  "$BASE_NAME-dist"
  "$BASE_NAME-v1"
  "$BASE_NAME-v2"
  "$BASE_NAME-old"
  "$BASE_NAME-new"
  "v1-$BASE_NAME"
  "v2-$BASE_NAME"
  "$BASE_NAME.com-dev"
  "$BASE_NAME.com-test"
  "$BASE_NAME.com-prod"
  "dev-$BASE_NAME.com"
  "test-$BASE_NAME.com"
  "prod-$BASE_NAME.com"
  "${BASE_NAME//./-}"
  "www-${BASE_NAME//./-}"
  "${BASE_NAME//./-}-dev"
  "${BASE_NAME//./-}-prod"
  "${BASE_NAME//./-}-logs"
  "${BASE_NAME//./-}-assets"
)

########################################
# Concurrency limit
########################################
threads=15

########################################
# Mark that we found something
########################################
mark_found() {
    [ "$CLEANUP_IN_PROGRESS" = "1" ] && return
    if [ -d "$tmpdir" ]; then
        echo 1 >> "$tmpdir/found_any_markers" 2>/dev/null || true
    fi
}

########################################
# Dedup arrays
########################################
declare -A seen_cli
declare -A seen_http
declare -A seen_https
declare -A seen_print

########################################
# Spinner pinned to one line, with PID guard
########################################
spinner() {
local pid=$1
if ! [[ "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then
return
fi
local delay=0.15
local spinstr="|/-\\"
echo -ne "\033[1A" >&2
echo -ne "\r" >&2
while kill -0 "$pid" 2>/dev/null; do
echo -ne "[${spinstr:0:1}] Working..." >&2
spinstr="${spinstr:1}${spinstr:0:1}"
echo -ne "\r" >&2
sleep $delay
done
echo -ne "\r" >&2
}

########################################
# Generate possible web endpoints
########################################
generate_web_endpoints() {
local bucket="$1"
local region="$2"
echo "$bucket" "$bucket.s3.amazonaws.com" "s3.amazonaws.com/$bucket" "$bucket.s3.$region.amazonaws.com" "$bucket.s3-website.$region.amazonaws.com" "$bucket.s3-website-$region.amazonaws.com" "$bucket.s3-$region.amazonaws.com" "s3.$region.amazonaws.com/$bucket" "s3-website.$region.amazonaws.com/$bucket" "s3-website-$region.amazonaws.com/$bucket" "s3-$region.amazonaws.com/$bucket" "$bucket.s3.dualstack.$region.amazonaws.com" "s3.dualstack.$region.amazonaws.com/$bucket"
}

########################################
# AWS CLI check
########################################
check_awscli() {
local bucket="$1"
[ "${seen_cli[$bucket]}" = "1" ] && return
if aws s3 ls "s3://$bucket" --no-sign-request &>/dev/null; then
mark_found
echo -e "\033[1;33m[AWS CLI]\033[0m Found: \033[1;32ms3://$bucket\033[0m \033[0;36m(no region)\033[0m"
fi
for region in "${regions[@]}"; do
if aws s3 ls "s3://$bucket" --no-sign-request --region "$region" &>/dev/null; then
mark_found
echo -e "\033[1;33m[AWS CLI]\033[0m Found: \033[1;32ms3://$bucket\033[0m \033[0;36m($region)\033[0m"
fi
done
seen_cli[$bucket]=1
}

########################################
# URL check (HTTP & HTTPS)
########################################
check_url() {
    # Exit immediately if cleanup is in progress
    [ "$CLEANUP_IN_PROGRESS" = "1" ] && return
    
    local url="$1"
    local bare="${url#http://}"
    bare="${bare#https://}"
    
    # Check if already processed to avoid duplicate work
    if [ -f "$tmpdir/checked_urls" ] && grep -qFx "$bare" "$tmpdir/checked_urls" 2>/dev/null; then
        return
    fi
    
    # Exit if cleanup started
    [ "$CLEANUP_IN_PROGRESS" = "1" ] && return
    
    # Create temporary files
    local temp_file=""
    local headers_file=""
    
    # Use trap to ensure temp files are cleaned up even if the function exits early
    cleanup_temp() {
        [ -n "$temp_file" ] && [ -f "$temp_file" ] && rm -f "$temp_file" 2>/dev/null
        [ -n "$headers_file" ] && [ -f "$headers_file" ] && rm -f "$headers_file" 2>/dev/null
    }
    trap cleanup_temp RETURN
    
    # Create temp files
    temp_file=$(mktemp) || return
    headers_file=$(mktemp) || { rm -f "$temp_file" 2>/dev/null; return; }
    
    # Record that we've checked this URL if tmpdir still exists
    if [ -d "$tmpdir" ]; then
        echo "$bare" >> "$tmpdir/checked_urls" 2>/dev/null || true
    else
        # tmpdir is gone, abort processing
        return
    fi
    
    local found_http=false found_https=false
    local http_url="" https_url=""

    for protocol in http https; do
        # Check again for cleanup before each protocol
        [ "$CLEANUP_IN_PROGRESS" = "1" ] && return
        [ ! -f "$temp_file" ] || [ ! -f "$headers_file" ] && return
        
        if [[ "$protocol://$bare" == *"s3-website"* ]]; then
            continue
        fi
        
        # Make sure temporary directory still exists
        if [ ! -d "$tmpdir" ]; then
            return
        fi
        
        local status_code=0
        local curl_cmd
        
        if [[ "$bare" =~ \.s3\. ]] || [[ "$bare" =~ s3\.amazonaws\.com ]]; then
            # Run curl with a timeout to prevent hanging
            if [ "$CLEANUP_IN_PROGRESS" = "1" ]; then return; fi
            status_code=$(curl --connect-timeout 3 -m 10 -s -D "$headers_file" -o "$temp_file" -w "%{http_code}" -H "Accept: text/html" "$protocol://$bare" 2>/dev/null || echo 0)
            
            # Check for cleanup or empty files
            if [ "$CLEANUP_IN_PROGRESS" = "1" ] || [ ! -f "$temp_file" ] || [ ! -f "$headers_file" ]; then return; fi
            
            if [ -z "$status_code" ]; then status_code=0; fi
            if [ "$status_code" -eq 403 ] && grep -qi "AccessDenied" "$temp_file" 2>/dev/null; then
                echo -e "\033[1;33m[WEB]\033[0m Found (Access Denied):\033[1;33m$protocol://$bare\033[0m"
                if [ -d "$tmpdir" ]; then
                    echo "$protocol://$bare (Access Denied)" >> "$tmpdir/found_urls" 2>/dev/null || true
                    mark_found
                fi
            elif [ "$status_code" -eq 200 ] && grep -qi "<Contents>" "$temp_file" 2>/dev/null; then
                if [ "$protocol" == "https" ]; then
                    found_https=true; https_url="$protocol://$bare"
                else
                    found_http=true; http_url="$protocol://$bare"
                fi
                if [ -d "$tmpdir" ]; then
                    echo "$protocol://$bare" >> "$tmpdir/found_urls" 2>/dev/null || true
                    mark_found
                fi
            fi
        else
            # Run curl with a timeout to prevent hanging
            if [ "$CLEANUP_IN_PROGRESS" = "1" ]; then return; fi
            status_code=$(curl --connect-timeout 3 -m 10 -L -s -D "$headers_file" -o "$temp_file" -w "%{http_code}" -H "Accept: text/html" "$protocol://$bare" 2>/dev/null || echo 0)
            
            # Check for cleanup or empty files
            if [ "$CLEANUP_IN_PROGRESS" = "1" ] || [ ! -f "$temp_file" ] || [ ! -f "$headers_file" ]; then return; fi
            
            if [ -z "$status_code" ]; then status_code=0; fi
            if [ "$status_code" -eq 200 ] && grep -qi "<Contents>" "$temp_file" 2>/dev/null; then
                if [ "$protocol" == "https" ]; then
                    found_https=true; https_url="$protocol://$bare"
                else
                    found_http=true; http_url="$protocol://$bare"
                fi
                if [ -d "$tmpdir" ]; then
                    echo "$protocol://$bare" >> "$tmpdir/found_urls" 2>/dev/null || true
                    mark_found
                fi
            fi
        fi
    done

    # Only output results if we haven't started cleanup
    if [ "$CLEANUP_IN_PROGRESS" = "0" ]; then
        if [ "$found_http" = true ] && [ -d "$tmpdir" ]; then
            # Use flock to ensure atomic operations on the printed_urls file
            if ! grep -Fxq "$http_url" "$tmpdir/printed_urls" 2>/dev/null; then
                (flock -w 1 200 || exit 0; 
                 # Check again after getting lock in case another process printed it
                 if ! grep -Fxq "$http_url" "$tmpdir/printed_urls" 2>/dev/null; then
                    echo "$http_url" >> "$tmpdir/printed_urls" 2>/dev/null
                    echo -e "\033[1;31m[WEB]\033[0m Accessible:\033[1;31m$http_url\033[0m"
                 fi) 200>"$tmpdir/print_lock" 2>/dev/null
            fi
        fi
        if [ "$found_https" = true ] && [ -d "$tmpdir" ]; then
            # Use flock to ensure atomic operations on the printed_urls file
            if ! grep -Fxq "$https_url" "$tmpdir/printed_urls" 2>/dev/null; then
                (flock -w 1 200 || exit 0; 
                 # Check again after getting lock in case another process printed it
                 if ! grep -Fxq "$https_url" "$tmpdir/printed_urls" 2>/dev/null; then
                    echo "$https_url" >> "$tmpdir/printed_urls" 2>/dev/null
                    echo -e "\033[1;32m[WEB]\033[0m Accessible:\033[1;32m$https_url\033[0m"
                 fi) 200>"$tmpdir/print_lock" 2>/dev/null
            fi
        fi
    fi
    
    # Temp files are cleaned up by the trap
}

########################################
# PHASE 1: S3 Web (Global)
########################################
web_checks_global() {
    echo "======== S3 Web (Global) ========"
    local c=0
    for variation in "${bucket_variations[@]}"; do
        ((c++))
        {
            check_url "http://$variation"
            check_url "https://$variation"
        } &
        if (( c % threads == 0 )); then
            wait
        fi
    done
    wait
}

########################################
# PHASE 2: S3 Web (Region-based)
########################################
web_checks_region_based() {
    echo "======== S3 Web (Region-based) ========"
    local c=0
    for variation in "${bucket_variations[@]}"; do
        for region in "${regions[@]}"; do
            ((c++))
            {
                for e in $(generate_web_endpoints "$variation" "$region"); do
                    check_url "http://$e"
                    check_url "https://$e"
                done
            } &
            if (( c % threads == 0 )); then
                wait
            fi
        done
    done
    wait
}

########################################
# PHASE 3: AWS CLI
########################################
aws_cli_checks() {
    echo "======== AWS CLI ========"
    local c=0
    for variation in "${bucket_variations[@]}"; do
        ((c++))
        check_awscli "$variation" &
        if (( c % threads == 0 )); then
            wait
        fi
    done
    wait
}

########################################
# MAIN
########################################
echo -e "\033[1;36m==== S3 Bucket Accessibility Check ====\033[0m"
echo -e "Base name: \033[1;33m$BASE_NAME\033[0m"
echo -e "[|] Working..."

(
    web_checks_global
    web_checks_region_based
    aws_cli_checks
) &
bg_pid=$!
spinner "$bg_pid"
wait "$bg_pid"

echo
if [ -s "$tmpdir/found_any_markers" ]; then
    echo -e "\033[1;32mDone. Found one or more accessible buckets above.\033[0m"
else
    echo -e "\033[1;31mNo accessible buckets found.\033[0m"
fi

rm -rf "$tmpdir"