#!/bin/bash

########################################
# Cleanup function
########################################
cleanup() {
    # Set cleanup flag first (used by background processes)
    CLEANUP_IN_PROGRESS=1
    echo -e "\nCleaning up..." >&2

    # ZSH-specific fix to prevent "Terminated" messages
    if [ -n "$ZSH_VERSION" ]; then
        # In ZSH, we can set the MONITOR option to off to prevent terminated messages
        setopt LOCAL_OPTIONS NO_MONITOR
    fi

    # Kill all AWS processes first
    pkill -f "aws s3 ls" 2>/dev/null || true
    
    # Kill curl processes next
    pkill -f "curl" 2>/dev/null || true
    
    # Kill all direct child processes
    pkill -P $$ 2>/dev/null || true
    
    # Give processes time to terminate
    sleep 1
    
    # Clean up temp directory if it exists
    if [ -n "$tmpdir" ] && [ -d "$tmpdir" ]; then
        rm -rf "$tmpdir" 2>/dev/null || true
    fi
    
    echo "Done." >&2
    exit 0
}

########################################
# Initialize temp dir, markers, flag, and trap
########################################
tmpdir=$(mktemp -d)

# seed marker files so greps/appends never see "no such file"

touch "$tmpdir"/{checked_urls,found_urls,found_any_markers,printed_urls}
CLEANUP_IN_PROGRESS=0

# Only set up trap for INT and TERM, not EXIT to avoid double cleanup
trap 'cleanup' INT TERM

########################################
# Display usage
########################################
usage() {
echo "Usage: $0 -b bucket_name [-w] [-c]"
echo "  -b    The base bucket name (required)"
echo "  -w    Web checks only (no AWS CLI checks)"
echo "  -c    CLI checks only (no web checks)"
echo "If neither -w nor -c is specified, both checks will be performed."
exit 1
}

########################################
# Parse Command-Line
########################################
# Default: run both web and CLI checks
RUN_WEB_CHECKS=1
RUN_CLI_CHECKS=1

while getopts ":b:wc" opt; do
case $opt in
b) BASE_NAME=$OPTARG ;;
w) RUN_WEB_CHECKS=1; RUN_CLI_CHECKS=0 ;;
c) RUN_CLI_CHECKS=1; RUN_WEB_CHECKS=0 ;;
*) usage ;;
esac
done

if [ -z "$BASE_NAME" ]; then
usage
fi

# If both flags are specified, run both checks
if [ "$RUN_WEB_CHECKS" -eq 1 ] && [ "$RUN_CLI_CHECKS" -eq 1 ]; then
  # This is the default behavior
  :  # No-op
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
declare -A seen_nocliredundant
declare -A seen_http
declare -A seen_https
declare -A seen_print

########################################
# Spinner pinned to one line
########################################
spinner() {
  local pid=$1
  local delay=0.15
  local spinstr='|/-\\'

  # Move cursor up 1 line so we can overwrite the line we printed
  echo -ne "\033[1A" >&2
  echo -ne "\r" >&2

  while kill -0 "$pid" 2>/dev/null; do
    # Overwrite with spinner
    echo -ne "[${spinstr:0:1}] Working..." >&2
    spinstr="${spinstr:1}${spinstr:0:1}"
    echo -ne "\r" >&2
    sleep $delay
  done
  # Clear spinner line
  echo -ne "                       \r" >&2
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
  # Exit if cleanup in progress
  [ "$CLEANUP_IN_PROGRESS" = "1" ] && return
  
  local bucket="$1"

  # Skip if we've seen the base bucket before
  if [ "${seen_cli[$bucket]}" = "1" ]; then
    return
  fi
  
  # Mark this bucket as checked at the start to prevent duplicates
  seen_cli[$bucket]="1"

  # Determine which regions to check based on FAST_MODE
  local check_regions=()
  if [ "$FAST_MODE" = "1" ]; then
    check_regions=("${fast_regions[@]}")
  else
    check_regions=("${regions[@]}")
  fi

  # Create a global deduplication key for no-region checks
  local noregion_key="${bucket}_noregion"
  
  # Only check for no-region if we haven't seen it before
  if [ "${seen_cli[$noregion_key]}" != "1" ] && [ "$CLEANUP_IN_PROGRESS" != "1" ]; then
    # Mark as seen first to prevent duplicates
    seen_cli[$noregion_key]="1"
    
    if aws s3 ls "s3://$bucket" --no-sign-request &>/dev/null; then
      mark_found
      echo -e "\033[1;33m[AWS CLI]\033[0m Found: \033[1;32ms3://$bucket\033[0m \033[0;36m(no region)\033[0m"
    fi
  fi

  # Check each region with deduplication
  for region in "${check_regions[@]}"; do
    # Exit if cleanup started
    [ "$CLEANUP_IN_PROGRESS" = "1" ] && break
    
    # Create a unique key for this bucket+region combination
    local region_key="${bucket}_${region}"
    
    # Skip if we've already checked this bucket+region combination
    if [ "${seen_cli[$region_key]}" = "1" ]; then
      continue
    fi
    
    # Mark it as seen first to prevent duplicates
    seen_cli[$region_key]="1"
    
    if aws s3 ls "s3://$bucket" --no-sign-request --region "$region" &>/dev/null; then
      mark_found
      echo -e "\033[1;33m[AWS CLI]\033[0m Found: \033[1;32ms3://$bucket\033[0m \033[0;36m($region)\033[0m"
    fi
  done
}

########################################
# URL check (HTTP & HTTPS)
########################################
check_url() {
    local url="$1"

    # Exit if cleanup in progress
    [ "$CLEANUP_IN_PROGRESS" = "1" ] && return

    # Normalize URL format
    url="${url#http://}"
    url="${url#https://}"

    # Check if URL has been processed
    if [ -f "$tmpdir/checked_urls" ] && grep -qFx "$url" "$tmpdir/checked_urls" 2>/dev/null; then
        return
    fi
    
    # Mark as checked if tmpdir exists
    if [ -d "$tmpdir" ]; then
        echo "$url" >> "$tmpdir/checked_urls" 2>/dev/null || true
    else
        # tmpdir is gone, abort processing
        return
    fi

    local temp_file=$(mktemp)
    local headers_file=$(mktemp)
    local found_http=false
    local found_https=false
    local http_url=""
    local https_url=""

    # Use trap to ensure temp files are cleaned up even if the function exits early
    cleanup_temp() {
        [ -f "$temp_file" ] && rm -f "$temp_file" 2>/dev/null
        [ -f "$headers_file" ] && rm -f "$headers_file" 2>/dev/null
    }
    trap cleanup_temp RETURN

    # Try both HTTP and HTTPS
    for protocol in "http" "https"; do
        # Exit if cleanup started
        [ "$CLEANUP_IN_PROGRESS" = "1" ] && return

        local full_url="${protocol}://${url}"

        # Skip s3-website endpoints entirely
        if [[ "$full_url" == *"s3-website"* ]]; then
            continue
        fi

        # HTTPS security flag
        local secure=""
        if [ "$protocol" = "https" ]; then
            secure="-k"
        fi

        # For S3 URLs, don't follow redirects
        if [[ "$full_url" == *".s3."* ]] || [[ "$full_url" == *"s3.amazonaws.com"* ]]; then
            # Check without following redirects
            status_code=$(curl $secure -m 10 -s -D "$headers_file" -o "$temp_file" -w "%{http_code}" -H "Accept: text/html,application/xhtml+xml" "$full_url" 2>/dev/null || echo 0)

            # Check for interrupted execution
            if [ "$CLEANUP_IN_PROGRESS" = "1" ] || [ ! -f "$temp_file" ] || [ ! -f "$headers_file" ]; then
                return
            fi

            # For S3 URLs, a 403 (Forbidden) means the bucket exists but is private
            if [[ "$status_code" =~ ^[0-9]+$ ]] && [ "$status_code" -eq 403 ]; then
                if grep -q -i "AccessDenied" "$temp_file" 2>/dev/null && ! grep -q -i "InvalidBucketName\|NoSuchBucket" "$temp_file" 2>/dev/null; then
                    echo -e "\033[1;33m[WEB]\033[0m Found (Access Denied): \033[1;33m$full_url\033[0m"
                    if [ -d "$tmpdir" ]; then
                        echo "$full_url (Access Denied)" >> "$tmpdir/found_urls" 2>/dev/null || true
                        mark_found
                    fi
                fi
            # For 200 responses, verify it's actually a valid S3 response
            elif [[ "$status_code" =~ ^[0-9]+$ ]] && [ "$status_code" -eq 200 ]; then
                # Check for actual S3 bucket content
                if ! grep -q -i "<Error>\|NoSuchBucket\|WebsiteRedirect\|Request does not contain a bucket name\|PermanentRedirect\|TemporaryRedirect" "$temp_file" 2>/dev/null; then
                    if grep -q -i "ListBucketResult\|<Contents>" "$temp_file" 2>/dev/null; then
                        # Verify it's not just an error page masquerading as 200
                        if ! grep -q -i "The specified bucket does not exist\|InvalidBucketName" "$temp_file" 2>/dev/null; then
                            if [ "$protocol" = "https" ]; then
                                found_https=true
                                https_url="$full_url"
                            else
                                found_http=true
                                http_url="$full_url"
                            fi
                            if [ -d "$tmpdir" ]; then
                                echo "$full_url" >> "$tmpdir/found_urls" 2>/dev/null || true
                                mark_found
                            fi
                        fi
                    fi
                fi
            fi
        else
            # For non-S3 URLs, check if they resolve to actual content
            status_code=$(curl $secure -m 10 -L -s -D "$headers_file" -o "$temp_file" -w "%{http_code}" -H "Accept: text/html,application/xhtml+xml" "$full_url" 2>/dev/null || echo 0)
            
            # Check for interrupted execution
            if [ "$CLEANUP_IN_PROGRESS" = "1" ] || [ ! -f "$temp_file" ] || [ ! -f "$headers_file" ]; then
                return
            fi

            # Ensure status_code is a valid integer
            if [[ "$status_code" =~ ^[0-9]+$ ]] && [ "$status_code" -eq 200 ]; then
                # Make sure it's not an error page or redirect
                if [ -s "$temp_file" ] && \
                   ! grep -q -i "<Error>\|WebsiteRedirect\|NoSuchBucket\|Request does not contain a bucket name\|301 Moved Permanently\|404 Not Found\|PermanentRedirect\|TemporaryRedirect" "$temp_file" 2>/dev/null; then

                    # Additional validation for potential S3 content
                    if grep -q -i "ListBucketResult\|<Contents>\|<Key>" "$temp_file" 2>/dev/null; then
                        # Final check for masked error responses
                        if ! grep -q -i "The specified bucket does not exist\|InvalidBucketName" "$temp_file" 2>/dev/null; then
                            if [ "$protocol" = "https" ]; then
                                found_https=true
                                https_url="$full_url"
                            else
                                found_http=true
                                http_url="$full_url"
                            fi
                            if [ -d "$tmpdir" ]; then
                                echo "$full_url" >> "$tmpdir/found_urls" 2>/dev/null || true
                                mark_found
                            fi
                        fi
                    fi
                fi
            # For 403 responses, check if they indicate a real bucket
            elif [[ "$status_code" =~ ^[0-9]+$ ]] && [ "$status_code" -eq 403 ]; then
                if grep -q -i "AccessDenied" "$temp_file" 2>/dev/null && ! grep -q -i "NoSuchBucket\|InvalidBucketName" "$temp_file" 2>/dev/null; then
                    echo -e "\033[1;33m[WEB]\033[0m Found (Access Denied): \033[1;33m$full_url\033[0m"
                    if [ -d "$tmpdir" ]; then
                        echo "$full_url (Access Denied)" >> "$tmpdir/found_urls" 2>/dev/null || true
                        mark_found
                    fi
                fi
            fi
        fi
    done

    # Check if we need to print anything (if cleanup not in progress)
    if [ "$CLEANUP_IN_PROGRESS" = "0" ] && [ -d "$tmpdir" ]; then
        # Print results in order, but only if not already printed
        if [ "$found_http" = true ]; then
            if ! grep -Fxq "$http_url" "$tmpdir/printed_urls" 2>/dev/null; then
                (flock -w 1 200 || exit 0;
                 if ! grep -Fxq "$http_url" "$tmpdir/printed_urls" 2>/dev/null; then
                     echo "$http_url" >> "$tmpdir/printed_urls" 2>/dev/null || true
                     echo -e "\033[1;31m[WEB]\033[0m Accessible: \033[1;31m$http_url\033[0m"
                 fi) 200>"$tmpdir/print_lock" 2>/dev/null
            fi
        fi
        if [ "$found_https" = true ]; then
            if ! grep -Fxq "$https_url" "$tmpdir/printed_urls" 2>/dev/null; then
                (flock -w 1 200 || exit 0;
                 if ! grep -Fxq "$https_url" "$tmpdir/printed_urls" 2>/dev/null; then
                     echo "$https_url" >> "$tmpdir/printed_urls" 2>/dev/null || true
                     echo -e "\033[1;32m[WEB]\033[0m Accessible: \033[1;32m$https_url\033[0m"
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
    # Return if cleanup in progress
    [ "$CLEANUP_IN_PROGRESS" = "1" ] && return
    
    echo "======== S3 Web (Global) ========"
    local c=0
    for variation in "${bucket_variations[@]}"; do
        # Exit early if cleanup triggered
        [ "$CLEANUP_IN_PROGRESS" = "1" ] && break
        
        ((c++))
        {
            check_url "http://$variation"
            check_url "https://$variation"
        } &
        if (( c % threads == 0 )); then
            wait
        fi
        
        # Check again for cleanup
        [ "$CLEANUP_IN_PROGRESS" = "1" ] && break
    done
    
    # Only wait if not in cleanup
    [ "$CLEANUP_IN_PROGRESS" = "0" ] && wait
}

########################################
# PHASE 2: S3 Web (Region-based)
########################################
web_checks_region_based() {
    # Return if cleanup in progress
    [ "$CLEANUP_IN_PROGRESS" = "1" ] && return

    echo "======== S3 Web (Region-based) ========"
    local c=0

    # Determine which regions to check based on FAST_MODE
    local check_regions=()
    if [ "$FAST_MODE" = "1" ]; then
        check_regions=("${fast_regions[@]}")
        echo -e "\033[1;33mRunning in FAST mode (checking only ${#check_regions[@]} regions)\033[0m"
    else
        check_regions=("${regions[@]}")
    fi

    for variation in "${bucket_variations[@]}"; do
        # Exit early if cleanup triggered
        [ "$CLEANUP_IN_PROGRESS" = "1" ] && break
        
        for region in "${check_regions[@]}"; do
            # Check for cleanup flag
            [ "$CLEANUP_IN_PROGRESS" = "1" ] && break
            
            ((c++))
            {
                endpoints=( $(generate_web_endpoints "$variation" "$region") )
                for e in "${endpoints[@]}"; do
                    # Skip if cleanup in progress
                    [ "$CLEANUP_IN_PROGRESS" = "1" ] && break
                    
                    check_url "http://$e"
                    check_url "https://$e"
                done
            } &
            if (( c % threads == 0 )); then
                # Only wait if not in cleanup
                [ "$CLEANUP_IN_PROGRESS" = "1" ] || wait
            fi
        done
        
        # Check again for cleanup
        [ "$CLEANUP_IN_PROGRESS" = "1" ] && break
    done
    
    # Only wait if not in cleanup
    [ "$CLEANUP_IN_PROGRESS" = "0" ] && wait
}

########################################
# PHASE 3: AWS CLI
########################################
aws_cli_checks() {
    echo "======== AWS CLI ========"
    # Return immediately if cleanup is in progress
    [ "$CLEANUP_IN_PROGRESS" = "1" ] && return
    
    # Run checks in serial to prevent duplication issues with associative arrays
    for variation in "${bucket_variations[@]}"; do
        # Exit early if cleanup started
        [ "$CLEANUP_IN_PROGRESS" = "1" ] && break
        
        # Run checks serially to avoid duplication
        check_awscli "$variation"
        
        # Check again for cleanup
        [ "$CLEANUP_IN_PROGRESS" = "1" ] && break
    done
}

########################################
# MAIN
########################################
echo -e "\033[1;36m==== S3 Bucket Accessibility Check ====\033[0m"
echo -e "Base name: \033[1;33m$BASE_NAME\033[0m"

# Show which checks will be run
if [ "$RUN_WEB_CHECKS" -eq 1 ] && [ "$RUN_CLI_CHECKS" -eq 1 ]; then
    echo -e "Mode: \033[1;36mRunning both Web and CLI checks\033[0m"
elif [ "$RUN_WEB_CHECKS" -eq 1 ]; then
    echo -e "Mode: \033[1;36mWeb checks only\033[0m"
elif [ "$RUN_CLI_CHECKS" -eq 1 ]; then
    echo -e "Mode: \033[1;36mCLI checks only\033[0m"
fi

echo -e "[|] Working..."

(
    # Only run web checks if the flag is set
    if [ "$RUN_WEB_CHECKS" -eq 1 ]; then
        web_checks_global
        web_checks_region_based
    fi
    # Only run CLI checks if the flag is set
    if [ "$RUN_CLI_CHECKS" -eq 1 ]; then
        aws_cli_checks
    fi
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