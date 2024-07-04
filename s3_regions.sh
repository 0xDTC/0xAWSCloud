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

# Iterate through each region and check the bucket
for region in "${regions[@]}"; do
  sudo aws s3 ls s3://"$BUCKET_NAME"/ --no-sign-request --region "$region" 2>/dev/null

  # Check the exit status of the last command
  if [ $? -eq 0 ]; then
    echo "Bucket '$BUCKET_NAME' found in region '$region'."
  else
    echo "Bucket '$BUCKET_NAME' not found in region '$region'."
  fi
done
