<a href="https://www.buymeacoffee.com/0xDTC"><img src="https://img.buymeacoffee.com/button-api/?text=Buy me a knowledge&emoji=📖&slug=0xDTC&button_colour=FF5F5F&font_colour=ffffff&font_family=Comic&outline_colour=000000&coffee_colour=FFDD00" /></a>

# AWS Security Scripts

## s3_regions.sh

A comprehensive S3 bucket accessibility checker that tests for publicly accessible buckets across all AWS regions.

### Features
- Tests bucket accessibility via HTTP and HTTPS
- Checks AWS CLI access with and without region specification
- Tests multiple bucket name variations and patterns
- Covers all AWS regions including GovCloud and China regions
- Prevents duplicate discoveries
- Color-coded output (red for HTTP, green for HTTPS)
- Concurrent processing for faster results
- No external dependencies required

### Usage
```bash
./s3_regions.sh -b bucket_name
```

### Example
```bash
./s3_regions.sh -b example
```

### Output
- Shows accessible buckets via HTTP (in red)
- Shows accessible buckets via HTTPS (in green)
- Shows accessible buckets via AWS CLI (with region information)
- Provides a summary of all discoveries

### Web output needs as fix

### Bucket Name Variations
The script tests multiple variations of the provided bucket name:
- Base name
- www. prefix/suffix
- Domain-style variations
- Environment prefixes/suffixes (dev, staging, prod)
- Common prefixes/suffixes (logs, backups, assets, etc.)
- S3-specific variations
- Hyphen/underscore variants
- And more...

### Requirements
- Bash shell
- curl
- AWS CLI (optional, for AWS CLI checks)

### Note
This tool is for security testing purposes only. Use responsibly and with proper authorization.

2. More coming soon
