#!/bin/bash

########################################
# Usage
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
# Comprehensive AWS Regions
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
# BIG Bucket Name Variations
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
# Global Config
########################################
threads=5      # concurrency limit
found_any=0    # flag if anything is found

# Keep track of duplicates
declare -A seen_cli
declare -A seen_http
declare -A seen_https

########################################
# Spinner (prints to stderr), pinned on one line
########################################
spinner() {
  local pid=$1
  local delay=0.15
  local spinstr='|/-\'

  # Move cursor up 1 line so we overwrite the printed line
  echo -ne "\033[1A" >&2
  echo -ne "\r" >&2

  while kill -0 "$pid" 2>/dev/null; do
    # Overwrite with spinner frame
    echo -ne "[${spinstr:0:1}] Working..." >&2
    spinstr="${spinstr:1}${spinstr:0:1}"
    echo -ne "\r" >&2
    sleep $delay
  done

  # Clear spinner line
  echo -ne "                       \r" >&2
}

########################################
# AWS CLI Check
########################################
check_awscli() {
  local bucket="$1"

  # Skip if already found
  if [ "${seen_cli[$bucket]}" = "1" ]; then
    return
  fi

  # (1) No-region
  if aws s3 ls "s3://$bucket" --no-sign-request &>/dev/null; then
    found_any=1
    echo -e "\033[1;33m[AWS CLI]\033[0m Found: \033[1;32ms3://$bucket\033[0m \033[0;36m(no region)\033[0m"
  fi

  # (2) Region-based
  for region in "${regions[@]}"; do
    if aws s3 ls "s3://$bucket" --no-sign-request --region "$region" &>/dev/null; then
      found_any=1
      echo -e "\033[1;33m[AWS CLI]\033[0m Found: \033[1;32ms3://$bucket\033[0m \033[0;36m($region)\033[0m"
      # no break => list all matches
    fi
  done

  seen_cli[$bucket]="1"
}

########################################
# HTTP / HTTPS => 200 check
########################################
check_http() {
  local url="$1"
  local proto="$2"

  if [ "$proto" = "HTTP" ] && [ "${seen_http[$url]}" = "1" ]; then
    return
  elif [ "$proto" = "HTTPS" ] && [ "${seen_https[$url]}" = "1" ]; then
    return
  fi

  local code
  code=$(curl -s -L -o /dev/null -w "%{http_code}" "$url")

  if [ "$code" = "200" ]; then
    found_any=1
    if [ "$proto" = "HTTP" ]; then
      echo -e "\033[1;31m[HTTP 200]\033[0m Accessible: \033[1;31m$url\033[0m"
      seen_http[$url]="1"
    else
      echo -e "\033[1;32m[HTTPS 200]\033[0m Accessible: \033[1;32m$url\033[0m"
      seen_https[$url]="1"
    fi
  fi
}

########################################
# AWS CLI Checks - concurrency
########################################
aws_cli_checks() {
  echo "======== AWS CLI ========"
  local count=0
  for variation in "${bucket_variations[@]}"; do
    ((count++))
    check_awscli "$variation" &

    if [ $((count % threads)) -eq 0 ]; then
      wait
    fi
  done
  wait
}

########################################
# S3 Web Checks - concurrency
########################################
web_checks() {
  echo "======== S3 Web ========"
  local count=0
  for variation in "${bucket_variations[@]}"; do
    ((count++))
    {
      check_http "http://$variation" "HTTP"
      check_http "https://$variation" "HTTPS"
    } &

    if [ $((count % threads)) -eq 0 ]; then
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
# Print the spinner line (will be overwritten by spinner)
echo -e "[|] \033[1;37mWorking...\033[0m"

(
  # 1) AWS CLI checks
  aws_cli_checks

  # 2) S3 Web checks
  web_checks
) &

bg_pid=$!
spinner "$bg_pid"
wait "$bg_pid"

echo
if [ "$found_any" -eq 0 ]; then
  echo -e "\033[1;31mNo accessible buckets found.\033[0m"
else
  echo -e "\033[1;32mDone. Found one or more accessible buckets above.\033[0m"
fi
