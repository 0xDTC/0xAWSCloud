#!/bin/bash

# Function to display usage
usage() {
  echo "Usage: $0 -b bucket_name"
  echo "  -b    Specify the bucket name (required)"
  exit 1
}

# Parse command-line options
while getopts ":b:" opt; do
  case $opt in
    b)
      BUCKET_NAME=$OPTARG
      ;;
    *)
      usage
      ;;
  esac
done

# Check if bucket name is provided
if [ -z "$BUCKET_NAME" ]; then
  usage
fi

# Comprehensive list of AWS regions
regions=(
  "us-east-1"
  "us-east-2"
  "us-west-1"
  "us-west-2"
  "af-south-1"
  "ap-east-1"
  "ap-southeast-1"
  "ap-southeast-2"
  "ap-southeast-3"
  "ap-northeast-1"
  "ap-northeast-2"
  "ap-northeast-3"
  "ap-south-1"
  "ca-central-1"
  "cn-north-1"
  "cn-northwest-1"
  "eu-central-1"
  "eu-west-1"
  "eu-west-2"
  "eu-west-3"
  "eu-north-1"
  "eu-south-1"
  "me-south-1"
  "me-central-1"
  "sa-east-1"
  "us-gov-east-1"
  "us-gov-west-1"
  "us-iso-east-1"
  "us-iso-west-1"
  "us-isob-east-1"
)

# Possible bucket name variations
bucket_variations=(
  "$BUCKET_NAME"
  "www.$BUCKET_NAME"
  "$BUCKET_NAME-www"
  "$BUCKET_NAME-s3"
  "$BUCKET_NAME-$region"
)

# Flag to track if a bucket was found
found=0

# Progress bar function
progress_bar() {
  local progress=$1
  local total=$2
  local width=50  # Width of the progress bar
  local percent=$((progress * 100 / total))
  local filled=$((progress * width / total))
  local empty=$((width - filled))

  # Create the progress bar visual
  printf "\rProgress: ["
  printf "%0.s#" $(seq 1 $filled)
  printf "%0.s " $(seq 1 $empty)
  printf "] %d%%" "$percent"
}

# Function to check buckets in parallel threads
check_bucket() {
  local region=$1
  local variation=$2

  endpoints=(
    "s3.amazonaws.com/$variation"
    "$variation.s3.amazonaws.com"
    "$variation.s3.$region.amazonaws.com"
    "$variation.s3-website.$region.amazonaws.com"
  )

  for endpoint in "${endpoints[@]}"; do
    aws s3 ls s3://"$variation" --no-sign-request --region "$region" 2>/dev/null

    if [ $? -eq 0 ]; then
      echo -e "\nBucket '$variation' is accessible without credentials at endpoint '$endpoint' in region '$region'."
      found=1
    fi
  done
}

# Limit concurrency to 10 threads
threads=10
counter=0

# Calculate total checks for progress tracking
total_checks=$(( ${#regions[@]} * ${#bucket_variations[@]} ))

# Iterate through each region and variation, launching checks in the background
for region in "${regions[@]}"; do
  for variation in "${bucket_variations[@]}"; do
    ((counter++))
    check_bucket "$region" "$variation" &  # Run in the background

    # Display progress bar
    progress_bar $counter $total_checks

    # Wait if 10 threads are running
    if [ $((counter % threads)) -eq 0 ]; then
      wait
    fi
  done
done

# Wait for any remaining threads
wait

# Final message
if [ $found -eq 0 ]; then
  echo -e "\nNo publicly accessible buckets found."
else
  echo -e "\nPublicly accessible bucket(s) found!"
fi