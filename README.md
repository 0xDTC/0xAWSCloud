<a href="https://www.buymeacoffee.com/0xDTC"><img src="https://img.buymeacoffee.com/button-api/?text=Buy me a knowledge&emoji=📖&slug=0xDTC&button_colour=FF5F5F&font_colour=ffffff&font_family=Comic&outline_colour=000000&coffee_colour=FFDD00" /></a>

# AWS Security Scripts

## s3_regions.py

A comprehensive S3 bucket accessibility checker that tests for publicly accessible buckets across all AWS regions, using both AWS CLI and web-based checks. Tests bucket permissions for GET, PUT, and DELETE operations to identify full write access.

### Features
- Tests bucket accessibility via HTTP and HTTPS
- Checks AWS CLI access across all AWS regions
- Tests PUT and DELETE permissions via both AWS CLI and HTTP/S
- Tests over 70 bucket name variations and patterns
- Checks multiple URL formats for each bucket variation:
  - Direct bucket access (bucket.com)
  - Standard S3 endpoints (bucket.s3.amazonaws.com)
  - Regional endpoints (bucket.s3.region.amazonaws.com)
  - Hyphenated endpoints (bucket.s3-region.amazonaws.com)
  - Website endpoints (bucket.s3-website.region.amazonaws.com)
  - Dualstack endpoints (bucket.s3.dualstack.region.amazonaws.com)
- Extended S3 feature support including requester pays settings
- Custom message input for PUT/DELETE tests with options to: test only PUT, test both PUT and DELETE, or skip all write tests
- Color-coded output (red for HTTP, green for HTTPS)
- Threaded concurrent processing for faster results
- Progress counter for visibility
- Real-time feedback on accessible buckets
- Automatic TLS/SSL certificate validation bypass for HTTPS endpoints
- Configurable concurrency via thread control

### Usage
```bash
python3 s3_regions.py -b bucket_name [-c] [-w] [-v] [-t THREADS]
```

Options:
- `-b, --bucket`: Specify the bucket name to check (required)
- `-c, --cli-only`: Only perform AWS CLI checks
- `-w, --web-only`: Only perform web checks
- `-v, --verbose`: Show verbose output (all attempts)
- `-t, --threads`: Number of concurrent threads for web checks (default: 30)

By default, both CLI and web checks are performed.

### Example
```bash
python3 s3_regions.py -b acme-corp.com
```

Example Output:
```
==== S3 Bucket Accessibility Check ====
Base name: acme-corp.com
Mode: Both Web and CLI checks

Enter the message to put in your test file (cannot be empty):
> This is a security test. Contact security@example.com if found.

Choose testing options:
  y - Test ONLY PUT operations (skip DELETE)
  n - Test both PUT and DELETE operations
  s - Skip all write tests (no PUT or DELETE)
Your choice [y/N/s]: n
Will perform both PUT and DELETE checks.

Using test message: 'This is a security test. Contact security@example.com if found.'

[AWS CLI] Found: s3://acme-corp.com No Region (objects: 1342) (PUT, DELETE)
[AWS CLI] Found: s3://acme-corp.com us-east-1 (objects: 1342) (PUT)
[AWS CLI] Found: s3://acme-corp.com us-east-2 (objects: 1342)
[Web] Accessible: http://acme-corp.com.s3.amazonaws.com (PUT, DELETE)
[Web] Accessible: https://acme-corp.com.s3.amazonaws.com (DELETE)
[Web] Accessible: http://acme-corp.com.s3.us-west-2.amazonaws.com

Base bucket 'acme-corp.com' is accessible!
```

### Workflow
1. Parse command line arguments
2. Initialize variables and regions list
3. Prompt user for:
   - Custom message to use in test file
   - Testing options (PUT-only, PUT+DELETE, or skip all write tests)
4. Generate bucket name variations
5. If CLI checks enabled:
   - Check bucket accessibility via AWS CLI across all regions
   - Track number of objects in each accessible bucket
   - If write tests enabled, test PUT operations with AWS CLI (--no-sign-request) using custom message
   - If DELETE testing enabled, test DELETE operations only after successful PUT
   - Report which write operations succeed for each accessible bucket
6. If Web checks enabled:
   - Generate all endpoint URLs for each bucket variation
   - Check HTTP/HTTPS accessibility of each URL concurrently
   - Detect S3 bucket listings via `<ListBucketResult xmlns=` pattern
   - If write tests enabled, test PUT operations via HTTP/S for accessible buckets
   - If DELETE testing enabled, test DELETE operations only after successful PUT
   - Report accessible buckets with color-coded URLs and write permissions
7. Display summary of results

### Visual Workflow Diagram
```mermaid
graph TD
    A[Start] --> B[Parse Arguments]
    B --> C[Initialize Variables & Regions]
    C --> C1[Prompt for Custom Message]
    C1 --> C1a{Testing Option?}
    C1a -->|PUT+DELETE| C2a[Configure PUT+DELETE Testing]
    C1a -->|PUT only| C2b[Configure PUT-only Testing]
    C1a -->|Skip All| C2c[Skip All Write Tests]
    C2a & C2b & C2c --> C3[Create Test File with Custom Message]
    
    C3 --> D[Generate Bucket Variations]
    
    D --> E{Check Mode}
    E -->|CLI Mode| F[AWS CLI Checks]
    E -->|Web Mode| G[Web Checks]
    E -->|Both Modes| F & G
    
    F --> F1[Probe Each Region with AWS CLI]
    F1 --> F2[Process Results]
    F2 --> F2x{Write Tests Enabled?}
    F2x -->|Yes| F2a[Test PUT with AWS CLI]
    F2x -->|No| F3[Mark Found Buckets]
    
    F2a -->|PUT Success & DELETE Enabled| F2b[Test DELETE with AWS CLI]
    F2a & F2b --> F3
    
    G --> G1[Generate All URL Patterns]
    G1 --> G2[Thread Pool for Web Checks]
    G2 --> G3[Check URLs Concurrently]
    G3 --> G4[Detect Valid S3 Responses]
    G4 --> G4x{Write Tests Enabled?}
    G4x -->|Yes| G4a[Test PUT via HTTP/S]
    G4x -->|No| G5[Mark Found Buckets]
    
    G4a -->|PUT Success & DELETE Enabled| G4b[Test DELETE via HTTP/S]
    G4a & G4b --> G5
    
    F3 --> Z[Display Results]
    G5 --> Z
    Z --> END[End]
    
    subgraph "CLI Probe"
    F1
    F2
    F2a
    F2b
    F3
    end
    
    subgraph "Web Probe"
    G1
    G2
    G3
    G4
    G4a
    G4b
    G5
    end
    
    subgraph "Bucket Name Variations"
    V1[Base Name]
    V2[www. Variations]
    V3[Domain-style Variations]
    V4[Environment Tags]
    V5[Common Prefixes/Suffixes]
    V6[S3-specific Variations]
    end
```

### Bucket Name Variations
The script tests multiple variations of the provided bucket name, including:
- Base name
- www. prefix/suffix
- Domain-style variations
- Environment prefixes/suffixes (dev, staging, prod, etc.)
- Common prefixes/suffixes (logs, backups, assets, etc.)
- S3-specific variations
- Hyphen/underscore variants
- And many more...

### Requirements
- Python 3.6+
- AWS CLI (optional, for CLI checks)

### Note
This tool is for security testing purposes only. Use responsibly and with proper authorization.

## More coming soon
