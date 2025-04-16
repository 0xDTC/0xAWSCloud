#!/bin/bash

########################################
# Display usage
########################################
usage() {
  echo "Usage: $0 -b bucket_name"
  echo "  -b    The base bucket name (required)"
  exit 1
}

########################################
# Parse Command-Line
########################################
while getopts ":b:" opt; do
  case $opt in
    b)
      BASE_NAME=$OPTARG
      ;;
    *)
      usage
      ;;
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
  # 1. Straight base
  "$BASE_NAME"

  # 2. With 'www.' prefix or suffix
  "www.$BASE_NAME"
  "$BASE_NAME-www"

  # 3. Dotted domain style
  "$BASE_NAME.com"
  "www.$BASE_NAME.com"

  # 4. Dashed domain style
  "$BASE_NAME-com"
  "www-$BASE_NAME-com"

  # 5. Basic environment / stage suffixes
  "$BASE_NAME-dev"
  "$BASE_NAME-staging"
  "$BASE_NAME-test"
  "$BASE_NAME-qa"
  "$BASE_NAME-prod"

  # 6. Environment / stage prefixes
  "dev-$BASE_NAME"
  "staging-$BASE_NAME"
  "test-$BASE_NAME"
  "qa-$BASE_NAME"
  "prod-$BASE_NAME"

  # 7. Common suffixes/prefixes
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

  # 8. S3 reference
  "$BASE_NAME-s3"
  "s3-$BASE_NAME"

  # 9. Hyphen or underscore variants
  "${BASE_NAME/_/-}"
  "${BASE_NAME/-/_}"

  # 10. Sub-application markers
  "$BASE_NAME-app"
  "app-$BASE_NAME"
  "$BASE_NAME-service"
  "service-$BASE_NAME"
  "$BASE_NAME-storage"
  "$BASE_NAME-dist"

  # 11. Potential versioning
  "$BASE_NAME-v1"
  "$BASE_NAME-v2"
  "$BASE_NAME-old"
  "$BASE_NAME-new"
  "v1-$BASE_NAME"
  "v2-$BASE_NAME"

  # 12. Domain + environment combos
  "$BASE_NAME.com-dev"
  "$BASE_NAME.com-test"
  "$BASE_NAME.com-prod"
  "dev-$BASE_NAME.com"
  "test-$BASE_NAME.com"
  "prod-$BASE_NAME.com"

  # 13. Replacing '.' with '-' in domain style
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
threads=5

# We'll track findings in a temp dir, so concurrency doesn't break them
tmpdir=$(mktemp -d)

# Instead of a global variable for found_any, we'll store markers in a file
mark_found() {
  echo 1 >> "$tmpdir/found_any_markers"
}

########################################
# Dedup arrays
########################################
declare -A seen_cli
declare -A seen_http
declare -A seen_https

########################################
# Spinner pinned to one line
########################################
spinner() {
  local pid=$1
  local delay=0.15
  local spinstr='|/-\'

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
# generate_web_endpoints
# - region-based hostnames
########################################
generate_web_endpoints() {
  local bucket="$1"
  local region="$2"
  local endpoints=()

  # Common global forms
  endpoints+=("$bucket")
  endpoints+=("$bucket.s3.amazonaws.com")
  endpoints+=("s3.amazonaws.com/$bucket")

  # Region-based forms
  endpoints+=("$bucket.s3.$region.amazonaws.com")
  endpoints+=("$bucket.s3-website.$region.amazonaws.com")
  endpoints+=("$bucket.s3-website-$region.amazonaws.com")
  endpoints+=("$bucket.s3-$region.amazonaws.com")
  endpoints+=("s3.$region.amazonaws.com/$bucket")
  endpoints+=("s3-website.$region.amazonaws.com/$bucket")
  endpoints+=("s3-website-$region.amazonaws.com/$bucket")
  endpoints+=("s3-$region.amazonaws.com/$bucket")
  endpoints+=("$bucket.s3.dualstack.$region.amazonaws.com")
  endpoints+=("s3.dualstack.$region.amazonaws.com/$bucket")

  echo "${endpoints[@]}"
}

########################################
# AWS CLI check
########################################
check_awscli() {
  local bucket="$1"

  # skip if we've seen it
  if [ "${seen_cli[$bucket]}" = "1" ]; then
    return
  fi

  # no-region
  if aws s3 ls "s3://$bucket" --no-sign-request &>/dev/null; then
    mark_found
    echo -e "\033[1;33m[AWS CLI]\033[0m Found: \033[1;32ms3://$bucket\033[0m \033[0;36m(no region)\033[0m"
  fi

  # region-based
  for region in "${regions[@]}"; do
    if aws s3 ls "s3://$bucket" --no-sign-request --region "$region" &>/dev/null; then
      mark_found
      echo -e "\033[1;33m[AWS CLI]\033[0m Found: \033[1;32ms3://$bucket\033[0m \033[0;36m($region)\033[0m"
    fi
  done

  seen_cli[$bucket]="1"
}

########################################
# check_url
########################################
check_url() {
    local url="$1"
    local output_file="$2"
    
    # Normalize URL format
    url="${url#http://}"
    url="${url#https://}"
    
    # Check if URL has been processed
    if url_checked "$url"; then
        return
    fi
    mark_url_checked "$url"

    local temp_file=$(mktemp)
    local headers_file=$(mktemp)
    
    # Try both HTTP and HTTPS
    for protocol in "http" "https"; do
        local full_url="${protocol}://${url}"
        
        # Skip s3-website endpoints entirely
        if [[ "$full_url" == *"s3-website"* ]]; then
            continue
        fi
        
        # For S3 URLs, don't follow redirects
        if [[ "$full_url" == *".s3."* ]] || [[ "$full_url" == *"s3.amazonaws.com"* ]]; then
            # Check without following redirects
            status_code=$(curl -s -D "$headers_file" -o "$temp_file" -w "%{http_code}" --max-time 10 -H "Accept: text/html,application/xhtml+xml" "$full_url" 2>/dev/null)
            
            # For S3 URLs, a 403 (Forbidden) means the bucket exists but is private
            if [ "$status_code" -eq 403 ]; then
                if grep -q -i "AccessDenied" "$temp_file" && ! grep -q -i "InvalidBucketName\|NoSuchBucket" "$temp_file"; then
                    echo -e "\033[1;33m[S3 403]\033[0m Found (Access Denied): \033[1;33m$full_url\033[0m"
                    add_found_url "$full_url (Access Denied)"
                fi
            # For 200 responses, verify it's actually a valid S3 response
            elif [ "$status_code" -eq 200 ]; then
                # Check for actual S3 bucket content
                if ! grep -q -i "<Error>\|NoSuchBucket\|WebsiteRedirect\|Request does not contain a bucket name\|PermanentRedirect\|TemporaryRedirect" "$temp_file"; then
                    if grep -q -i "ListBucketResult\|<Contents>" "$temp_file"; then
                        # Verify it's not just an error page masquerading as 200
                        if ! grep -q -i "The specified bucket does not exist\|InvalidBucketName" "$temp_file"; then
                            echo -e "\033[1;32m[S3 200]\033[0m Accessible: \033[1;32m$full_url\033[0m"
                            add_found_url "$full_url"
                        fi
                    fi
                fi
            fi
        else
            # For non-S3 URLs, check if they resolve to actual content
            status_code=$(curl -L -s -D "$headers_file" -o "$temp_file" -w "%{http_code}" --max-time 10 -H "Accept: text/html,application/xhtml+xml" "$full_url" 2>/dev/null)
            
            if [ "$status_code" -eq 200 ]; then
                # Make sure it's not an error page or redirect
                if [ -s "$temp_file" ] && \
                   ! grep -q -i "<Error>\|WebsiteRedirect\|NoSuchBucket\|Request does not contain a bucket name\|301 Moved Permanently\|404 Not Found\|PermanentRedirect\|TemporaryRedirect" "$temp_file"; then
                    
                    # Additional validation for potential S3 content
                    if grep -q -i "ListBucketResult\|<Contents>\|<Key>" "$temp_file"; then
                        # Final check for masked error responses
                        if ! grep -q -i "The specified bucket does not exist\|InvalidBucketName" "$temp_file"; then
                            if [ "$protocol" = "https" ]; then
                                echo -e "\033[1;32mAccessible: \033[1;32m$full_url\033[0m"
                            else
                                echo -e "\033[1;31mAccessible: \033[1;31m$full_url\033[0m"
                            fi
                            add_found_url "$full_url"
                        fi
                    fi
                fi
            fi
        fi
    done
    
    rm -f "$temp_file" "$headers_file"
}

# Helper function to track checked URLs
url_checked() {
    local url="$1"
    [ -f "$tmpdir/checked_urls" ] && grep -q "^$url$" "$tmpdir/checked_urls" 2>/dev/null
}

mark_url_checked() {
    local url="$1"
    echo "$url" >> "$tmpdir/checked_urls"
}

# Helper function to add found URLs
add_found_url() {
    local url="$1"
    if ! grep -q "^$url$" "$tmpdir/found_urls" 2>/dev/null; then
        echo "$url" >> "$tmpdir/found_urls"
        mark_found
    fi
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
      check_url "http://$variation" "$tmpdir/global_checks.txt"
      check_url "https://$variation" "$tmpdir/global_checks.txt"
    } &

    if [ $((c % threads)) -eq 0 ]; then
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
        endpoints=( $(generate_web_endpoints "$variation" "$region") )
        for e in "${endpoints[@]}"; do
          check_url "http://$e" "$tmpdir/region_checks_$region.txt"
          check_url "https://$e" "$tmpdir/region_checks_$region.txt"
        done
      } &

      if [ $((c % threads)) -eq 0 ]; then
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
    if [ $((c % threads)) -eq 0 ]; then
      wait
    fi
  done
  wait
}

########################################
# MAIN
########################################
# Set up cleanup on script termination
trap 'cleanup' EXIT INT TERM

cleanup() {
    echo -e "\n\033[1;33mCleaning up...\033[0m"
    if [ -d "$tmpdir" ]; then
        rm -rf "$tmpdir"
    fi
    exit 0
}

echo -e "\033[1;36m==== S3 Bucket Accessibility Check ====\033[0m"
echo -e "Base name: \033[1;33m$BASE_NAME\033[0m"

# Print spinner line
echo -e "[|] \033[1;37mWorking...\033[0m"

(
  # Phase 1: S3 Web (Global)
  web_checks_global

  # Phase 2: S3 Web (Region-based)
  web_checks_region_based

  # Phase 3: AWS CLI
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