package main

import (
	"bufio"
	"bytes"
	"crypto/tls"
	"encoding/xml"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// ────────────────────────── constants

const testFilename = "Bug-Bounty-From-Production-Exploiter.txt"

var awsRegions = []string{
	"us-east-1", "us-east-2", "us-west-1", "us-west-2",
	"af-south-1", "ap-east-1", "ap-southeast-1", "ap-southeast-2",
	"ap-southeast-3", "ap-northeast-1", "ap-northeast-2", "ap-northeast-3",
	"ap-south-1", "ca-central-1",
	"cn-north-1", "cn-northwest-1",
	"eu-central-1", "eu-west-1", "eu-west-2", "eu-west-3",
	"eu-north-1", "eu-south-1",
	"me-south-1", "me-central-1",
	"sa-east-1",
	"us-gov-east-1", "us-gov-west-1",
	"us-iso-east-1", "us-iso-west-1", "us-isob-east-1",
}

var (
	totalRe    = regexp.MustCompile(`Total\s+Objects:\s+(\d+)`)
	errInParen = regexp.MustCompile(`\(([^)]+)\)`)
	// lsLineRe parses a line of `aws s3 ls --recursive` output: date time size key.
	lsLineRe = regexp.MustCompile(`^\S+\s+\S+\s+(\d+)\s+(.*)$`)
)

// ────────────────────────── bucket access record

type BucketAccess struct {
	Bucket  string
	Region  string // raw region string ("" for no-region / web)
	Mode    string // "cli" or "web"
	URL     string // base URL that worked (web mode only)
	CanList bool
	CanPut  bool
	CanGet  bool
	CanDel  bool
}

// ────────────────────────── XML types for S3 listing (web mode ls)

type ListBucketResult struct {
	XMLName               xml.Name         `xml:"ListBucketResult"`
	Name                  string           `xml:"Name"`
	Prefix                string           `xml:"Prefix"`
	IsTruncated           bool             `xml:"IsTruncated"`
	NextMarker            string           `xml:"NextMarker"`
	NextContinuationToken string           `xml:"NextContinuationToken"`
	Contents              []S3Object       `xml:"Contents"`
	CommonPrefixes        []S3CommonPrefix `xml:"CommonPrefixes"`
}

type S3Object struct {
	Key          string `xml:"Key"`
	LastModified string `xml:"LastModified"`
	Size         int64  `xml:"Size"`
}

type S3CommonPrefix struct {
	Prefix string `xml:"Prefix"`
}

// ────────────────────────── shell state

type ShellState struct {
	allAccess    []BucketAccess
	activeBucket string
	activeAccess *BucketAccess
	cwdPrefix    string
}

// ────────────────────────── flags

var (
	flagBucket  string
	flagList    string
	flagWebOnly bool
	flagCLIOnly bool
	flagNameVar bool
	flagVerbose bool
	flagThreads int
)

// ────────────────────────── runtime state

var (
	doWeb         bool
	doCLI         bool
	baseBuckets   []string
	baseName      string
	allVariations []string

	testContent string
	testPut     = true
	testDelete  = true

	mu           sync.Mutex
	stopAll      atomic.Bool
	checkedSet   = make(map[string]bool)
	foundBuckets = make(map[string]map[string]bool)

	accessList []BucketAccess
	accessMu   sync.Mutex

	sigCh chan os.Signal // package-level for signal handler swap

	tmpDir       string
	testFilePath string
	httpClient   *http.Client
)

// ────────────────────────── console helpers

func logMsg(msg string, showAlways bool) {
	if showAlways || flagVerbose {
		mu.Lock()
		fmt.Fprintf(os.Stdout, "\r%-80s\r", "")
		fmt.Println(msg)
		mu.Unlock()
	}
}

func progressCounter(current, total int) {
	mu.Lock()
	fmt.Fprintf(os.Stdout, "\r%-80s\r[%d/%d] Checking...", "", current, total)
	mu.Unlock()
}

func markFound(bucket, region string) {
	mu.Lock()
	defer mu.Unlock()
	if bucket != "" {
		if foundBuckets[bucket] == nil {
			foundBuckets[bucket] = make(map[string]bool)
		}
		if region != "" {
			foundBuckets[bucket][region] = true
		}
	}
}

func ensureTestFile() {
	_ = os.WriteFile(testFilePath, []byte(testContent), 0644)
}

func recordAccess(a BucketAccess) {
	accessMu.Lock()
	accessList = append(accessList, a)
	accessMu.Unlock()
}

// ────────────────────────── name variations

func bucketVariations(b string) []string {
	dotDash := strings.ReplaceAll(b, ".", "-")
	v := []string{
		b,
		"www." + b, b + "-www",
		b + ".com", "www." + b + ".com",
		b + "-com", "www-" + b + "-com",
		b + "-dev", b + "-staging", b + "-test", b + "-qa", b + "-prod",
		"dev-" + b, "staging-" + b, "test-" + b, "qa-" + b, "prod-" + b,
		b + "-logs", b + "-backups", b + "-archive", b + "-resources",
		b + "-files", b + "-images", b + "-static", b + "-uploads",
		b + "-cdn", b + "-content", b + "-assets", b + "-config",
		b + "-data", b + "-api",
		"cdn-" + b, "files-" + b, "uploads-" + b, "static-" + b,
		"assets-" + b, "logs-" + b, "backups-" + b, "archive-" + b,
		"resources-" + b,
		"s1-" + b, "s2-" + b, "s3-" + b,
		b + "-s1", b + "-s2", b + "-s3",
		"s3-" + b,
		strings.ReplaceAll(b, "_", "-"),
		strings.ReplaceAll(b, "-", "_"),
		b + "-app", "app-" + b,
		b + "-service", "service-" + b,
		b + "-storage", b + "-dist",
		b + "-v1", b + "-v2", b + "-old", b + "-new",
		"v1-" + b, "v2-" + b,
		b + ".com-dev", b + ".com-test", b + ".com-prod",
		"dev-" + b + ".com", "test-" + b + ".com", "prod-" + b + ".com",
		dotDash,
		"www-" + dotDash,
		dotDash + "-dev", dotDash + "-prod",
		dotDash + "-logs", dotDash + "-assets",
	}
	seen := make(map[string]bool, len(v))
	out := make([]string, 0, len(v))
	for _, s := range v {
		if !seen[s] {
			seen[s] = true
			out = append(out, s)
		}
	}
	return out
}

func buildVariations() []string {
	if flagNameVar {
		var all []string
		for _, b := range baseBuckets {
			all = append(all, bucketVariations(b)...)
		}
		seen := make(map[string]bool, len(all))
		out := make([]string, 0, len(all))
		for _, s := range all {
			if !seen[s] {
				seen[s] = true
				out = append(out, s)
			}
		}
		return out
	}
	return baseBuckets
}

// ────────────────────────── endpoint generation

func buildEndpoints(bucket, region string) []string {
	var urls []string
	for _, proto := range []string{"http", "https"} {
		urls = append(urls, proto+"://"+bucket)
		if region == "" {
			urls = append(urls,
				fmt.Sprintf("%s://%s.s3.amazonaws.com", proto, bucket),
				fmt.Sprintf("%s://s3.amazonaws.com/%s", proto, bucket),
			)
		} else {
			urls = append(urls,
				fmt.Sprintf("%s://%s.s3.%s.amazonaws.com", proto, bucket, region),
				fmt.Sprintf("%s://s3.%s.amazonaws.com/%s", proto, region, bucket),
				fmt.Sprintf("%s://%s.s3-%s.amazonaws.com", proto, bucket, region),
				fmt.Sprintf("%s://s3-%s.amazonaws.com/%s", proto, region, bucket),
				fmt.Sprintf("%s://%s.s3-website.%s.amazonaws.com", proto, bucket, region),
				fmt.Sprintf("%s://s3-website.%s.amazonaws.com/%s", proto, region, bucket),
				fmt.Sprintf("%s://s3-website-%s.amazonaws.com/%s", proto, region, bucket),
				fmt.Sprintf("%s://%s.s3-website-%s.amazonaws.com", proto, bucket, region),
				fmt.Sprintf("%s://%s.s3.dualstack.%s.amazonaws.com", proto, bucket, region),
				fmt.Sprintf("%s://s3.dualstack.%s.amazonaws.com/%s", proto, region, bucket),
			)
		}
	}
	return urls
}

// ────────────────────────── error code extraction

func extractErrorCode(text string) string {
	if m := errInParen.FindStringSubmatch(text); len(m) > 1 {
		return m[1]
	}
	if strings.Contains(text, "Traceback (most recent call last):") {
		return "Traceback"
	}
	for _, w := range []string{"AccessDenied", "NoSuchBucket", "InvalidBucketName"} {
		if strings.Contains(text, w) {
			return w
		}
	}
	return "Error"
}

// ────────────────────────── flags helper

func buildFlags(parts []string) string {
	if len(parts) > 0 {
		return " (" + strings.Join(parts, ", ") + ")"
	}
	return ""
}

// ────────────────────────── CLI probe

func cliProbe(bucket string) {
	if stopAll.Load() {
		return
	}

	allRegs := make([]string, 0, len(awsRegions)+1)
	allRegs = append(allRegs, "") // no-region first
	allRegs = append(allRegs, awsRegions...)
	totalRegs := len(allRegs)

	for i, region := range allRegs {
		if stopAll.Load() {
			return
		}
		progressCounter(i+1, totalRegs)

		// Skip already-found bucket+region
		mu.Lock()
		if regs, ok := foundBuckets[bucket]; ok {
			if region == "" || regs[region] {
				mu.Unlock()
				continue
			}
		}
		mu.Unlock()

		label := "No Region"
		if region != "" {
			label = region
		}

		// ── aws s3 ls ──
		args := []string{"s3", "ls", "s3://" + bucket, "--no-sign-request", "--summarize"}
		if region != "" {
			args = append(args, "--region", region)
		}

		bucketAccessible := false
		objectCount := ""
		errorOutput := ""

		out, err := exec.Command("aws", args...).CombinedOutput()
		outStr := string(out)
		if err == nil {
			if m := totalRe.FindStringSubmatch(outStr); len(m) > 1 {
				bucketAccessible = true
				objectCount = m[1]
			}
		} else {
			errorOutput = outStr
		}

		// ── PUT / GET / DELETE tests (skip if bucket doesn't exist) ──
		putOk, getOk, delOk := false, false, false
		isNoSuchBucket := strings.Contains(errorOutput, "NoSuchBucket")

		if !isNoSuchBucket {
			ensureTestFile()
			s3Obj := "s3://" + bucket + "/" + testFilename
			putArgs := []string{"s3", "cp", testFilePath, s3Obj, "--no-sign-request"}
			getArgs := []string{"s3", "cp", s3Obj, filepath.Join(tmpDir, "downloaded_"+testFilename), "--no-sign-request"}
			rmArgs := []string{"s3", "rm", s3Obj, "--no-sign-request"}
			if region != "" {
				putArgs = append(putArgs, "--region", region)
				getArgs = append(getArgs, "--region", region)
				rmArgs = append(rmArgs, "--region", region)
			}

			if testPut {
				if _, e := exec.Command("aws", putArgs...).CombinedOutput(); e == nil {
					putOk = true
				}
			}
			if putOk {
				if _, e := exec.Command("aws", getArgs...).CombinedOutput(); e == nil {
					getOk = true
				}
			}
			if testDelete && putOk {
				if _, e := exec.Command("aws", rmArgs...).CombinedOutput(); e == nil {
					delOk = true
				}
			}
		}

		// ── report ──
		if bucketAccessible || putOk || getOk || delOk {
			var fp []string
			if putOk {
				fp = append(fp, "PUT")
			}
			if getOk {
				fp = append(fp, "GET")
			}
			if delOk {
				fp = append(fp, "DELETE")
			}
			flags := buildFlags(fp)
			markFound(bucket, label)
			recordAccess(BucketAccess{
				Bucket: bucket, Region: region, Mode: "cli",
				CanList: bucketAccessible, CanPut: putOk, CanGet: getOk, CanDel: delOk,
			})

			if bucketAccessible {
				logMsg(fmt.Sprintf(
					"\033[1;33m[AWS CLI]\033[0m Found: \033[1;32ms3://%s\033[0m %s \033[0;36m(objects: %s)\033[0m%s",
					bucket, label, objectCount, flags), true)
			} else {
				logMsg(fmt.Sprintf(
					"\033[1;33m[AWS CLI]\033[0m Access Denied (but operations work): \033[1;32ms3://%s\033[0m %s%s",
					bucket, label, flags), true)
			}
		} else {
			code := "No operations succeeded"
			if errorOutput != "" {
				code = extractErrorCode(errorOutput)
			}
			logMsg(fmt.Sprintf(
				"\033[1;31m[AWS CLI]\033[0m Not accessible: \033[1;32ms3://%s\033[0m %s (%s)",
				bucket, label, code), true)
		}
	}
}

func runCLIChecks() {
	modeText := fmt.Sprintf("%d base bucket(s)", len(baseBuckets))
	if flagNameVar {
		modeText = fmt.Sprintf("%d bucket variation(s)", len(allVariations))
	}
	fmt.Printf("Checking CLI access for %s across %d regions...\n", modeText, len(awsRegions))

	for _, bkt := range allVariations {
		if stopAll.Load() {
			break
		}
		cliProbe(bkt)
	}
}

// ────────────────────────── web probe

func httpFetch(url string) (int, string) {
	return httpFetchLimit(url, 1<<20)
}

func httpFetchLimit(u string, max int64) (int, string) {
	resp, err := httpClient.Get(u)
	if err != nil {
		return 0, err.Error()
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, max))
	return resp.StatusCode, string(body)
}

func webCheck(url string) {
	mu.Lock()
	if checkedSet[url] || stopAll.Load() {
		mu.Unlock()
		return
	}
	checkedSet[url] = true
	mu.Unlock()

	status, body := httpFetch(url)

	bucketExists := false
	canList := false
	label := ""
	if status == 403 &&
		strings.Contains(body, "AccessDenied") &&
		!strings.Contains(body, "NoSuchBucket") &&
		!strings.Contains(body, "InvalidBucketName") {
		bucketExists = true
		label = "Found (Access Denied)"
	} else if status == 200 &&
		strings.Contains(body, "<ListBucketResult xmlns=") &&
		!strings.Contains(body, "NoSuchBucket") &&
		!strings.Contains(body, "InvalidBucketName") {
		bucketExists = true
		canList = true
		label = "Accessible"
	}

	// ── PUT / GET / DELETE via HTTP (skip if bucket doesn't exist or website endpoint) ──
	putOk, getOk, delOk := false, false, false
	isNoSuchBucket := strings.Contains(body, "NoSuchBucket")
	isWebsiteEndpoint := strings.Contains(url, "s3-website")

	if !isNoSuchBucket && !isWebsiteEndpoint {
		objectURL := strings.TrimRight(url, "/") + "/" + testFilename

		if testPut {
			req, err := http.NewRequest("PUT", objectURL, strings.NewReader(testContent))
			if err == nil {
				req.Header.Set("Content-Type", "text/plain")
				if resp, err := httpClient.Do(req); err == nil {
					_, _ = io.Copy(io.Discard, resp.Body)
					resp.Body.Close()
					if resp.StatusCode == 200 || resp.StatusCode == 201 || resp.StatusCode == 204 {
						putOk = true
					}
				}
			}
		}
		if putOk {
			req, err := http.NewRequest("GET", objectURL, nil)
			if err == nil {
				if resp, err := httpClient.Do(req); err == nil {
					_, _ = io.Copy(io.Discard, resp.Body)
					resp.Body.Close()
					if resp.StatusCode == 200 {
						getOk = true
					}
				}
			}
		}
		if testDelete && putOk {
			req, err := http.NewRequest("DELETE", objectURL, nil)
			if err == nil {
				if resp, err := httpClient.Do(req); err == nil {
					_, _ = io.Copy(io.Discard, resp.Body)
					resp.Body.Close()
					if resp.StatusCode == 200 || resp.StatusCode == 204 {
						delOk = true
					}
				}
			}
		}
	}

	// ── report ──
	if bucketExists || putOk || getOk || delOk {
		matchedBucket := ""
		for _, v := range allVariations {
			if strings.Contains(url, v) {
				matchedBucket = v
				break
			}
		}
		if matchedBucket == "" {
			matchedBucket = baseName
		}
		markFound(matchedBucket, "")
		recordAccess(BucketAccess{
			Bucket: matchedBucket, Region: "", Mode: "web", URL: url,
			CanList: canList, CanPut: putOk, CanGet: getOk, CanDel: delOk,
		})

		color := "\033[0m"
		if strings.HasPrefix(url, "https://") {
			color = "\033[1;32m"
		} else if strings.HasPrefix(url, "http://") {
			color = "\033[1;31m"
		}

		var fp []string
		if putOk {
			fp = append(fp, "PUT")
		}
		if getOk {
			fp = append(fp, "GET")
		}
		if delOk {
			fp = append(fp, "DELETE")
		}
		flags := buildFlags(fp)

		finalLabel := label
		if !bucketExists {
			finalLabel = "Access Denied (but operations work)"
		}

		mu.Lock()
		fmt.Fprintf(os.Stdout, "\r%-80s\r", "")
		fmt.Printf("[Web] %s: %s%s\033[0m%s\n", finalLabel, color, url, flags)
		mu.Unlock()
	} else if flagVerbose {
		logMsg(fmt.Sprintf("[Web] Not listable: %s", url), false)
	}
}

func runWebChecks() {
	bucketText := ""
	if len(baseBuckets) == 1 && !flagNameVar {
		bucketText = fmt.Sprintf("bucket '%s'", baseName)
	} else if flagNameVar {
		bucketText = fmt.Sprintf("%d bucket variation(s)", len(allVariations))
	} else {
		bucketText = fmt.Sprintf("%d bucket(s)", len(baseBuckets))
	}
	fmt.Printf("Checking web endpoints for %s...\n", bucketText)

	var allURLs []string
	for _, b := range allVariations {
		allURLs = append(allURLs, buildEndpoints(b, "")...)
		for _, r := range awsRegions {
			allURLs = append(allURLs, buildEndpoints(b, r)...)
		}
	}

	total := len(allURLs)
	var done atomic.Int64
	sem := make(chan struct{}, flagThreads)
	var wg sync.WaitGroup

	for _, u := range allURLs {
		if stopAll.Load() {
			break
		}
		wg.Add(1)
		sem <- struct{}{}
		go func(url string) {
			defer wg.Done()
			defer func() { <-sem }()
			webCheck(url)
			d := done.Add(1)
			progressCounter(int(d), total)
		}(u)
	}
	wg.Wait()
	fmt.Fprintf(os.Stdout, "\r%-80s\r", "")
}

// ────────────────────────── interactive prompts

func getTestParams() {
	scanner := bufio.NewScanner(os.Stdin)

	fmt.Println("\nChoose testing options:")
	fmt.Println("  p - Test PUT and GET operations (skip DELETE)")
	fmt.Println("  b - Test PUT, GET, and DELETE operations")
	fmt.Println("  s - Skip all write tests (no PUT, GET, or DELETE)")
	fmt.Print("Your choice [b/p/s]: ")

	choice := ""
	if scanner.Scan() {
		choice = strings.TrimSpace(strings.ToLower(scanner.Text()))
	}

	switch choice {
	case "s":
		testPut = false
		testDelete = false
		fmt.Print("Will skip all write tests (no PUT, GET, or DELETE).\n\n")
	case "p", "put":
		testPut = true
		testDelete = false
		fmt.Print("Will perform PUT and GET checks only (no DELETE).\n\n")
	default:
		testPut = true
		testDelete = true
		fmt.Print("Will perform PUT, GET, and DELETE checks.\n\n")
	}

	if testPut {
		fmt.Println("Enter the message to put in your test file (cannot be empty):")
		for testContent == "" {
			fmt.Print("> ")
			if scanner.Scan() {
				input := strings.TrimSpace(scanner.Text())
				if input != "" {
					testContent = input
				} else {
					fmt.Println("Message cannot be empty. Please enter a message:")
				}
			}
		}
		fmt.Printf("Using test message: '%s'\n\n", testContent)
	} else {
		testContent = "No write tests enabled"
	}
}

// ────────────────────────── bucket loading

func loadBucketsFromFile(path string) []string {
	f, err := os.Open(path)
	if err != nil {
		fmt.Printf("Error: File '%s' not found.\n", path)
		os.Exit(1)
	}
	defer f.Close()

	var buckets []string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line != "" && !strings.HasPrefix(line, "#") {
			buckets = append(buckets, line)
		}
	}
	if err := sc.Err(); err != nil {
		fmt.Printf("Error reading file '%s': %v\n", path, err)
		os.Exit(1)
	}
	if len(buckets) == 0 {
		fmt.Printf("Error: No bucket names found in '%s'.\n", path)
		os.Exit(1)
	}
	return buckets
}

// ────────────────────────── interactive shell helpers

func s3KeyToURLPath(key string) string {
	parts := strings.Split(key, "/")
	for i, p := range parts {
		parts[i] = url.PathEscape(p)
	}
	return strings.Join(parts, "/")
}

func resolveKey(state *ShellState, key string) string {
	if strings.HasPrefix(key, "/") {
		return strings.TrimPrefix(key, "/")
	}
	return state.cwdPrefix + key
}

func requireActive(state *ShellState) bool {
	if state.activeAccess == nil {
		fmt.Println("No bucket selected. Use 'buckets' to list, then 'use <bucket>' to select.")
		return false
	}
	return true
}

func buildPrompt(state *ShellState) string {
	prompt := "\033[1;33m0xS3\033[0m"
	if state.activeBucket != "" {
		prompt += fmt.Sprintf(":\033[1;32m%s\033[0m", state.activeBucket)
		if state.cwdPrefix != "" {
			prompt += "/" + strings.TrimRight(state.cwdPrefix, "/")
		}
	}
	return prompt + "> "
}

// ────────────────────────── shell commands

func shellHelp() {
	fmt.Println(`
Available commands:
  buckets                  List all found buckets with access info
  use <bucket> [web|cli]   Select active bucket (or: use <number>)
  ls [prefix]              List objects in current prefix
  cd <path>                Change prefix (.. = up, / = root)
  pwd                      Show current s3://bucket/prefix
  cat <key>                Print object contents to stdout
  download <key> [local]   Download object to local file  (aliases: dl, get)
  upload <local> <key>     Upload local file to bucket    (aliases: ul, put)
  rm <key>                 Delete an object               (aliases: del, delete)
  head <key>               Show object metadata            (alias: info)
  find <substr> [prefix]   Search object keys (recursive, case-insensitive)
  grep <regexp> [prefix]   Search inside object contents (recursive)
  edit <key>               Edit object in $EDITOR, overwrite on save
  replace <key> <o> <n>    Substitute text in an object   (alias: sed)
  help                     Show this help
  exit                     Exit the shell (also: Ctrl+C)

Keys are relative to current prefix. Use /key for absolute paths.`)
}

func shellBuckets(state *ShellState) {
	if len(state.allAccess) == 0 {
		fmt.Println("No accessible buckets found.")
		return
	}
	fmt.Println("\nAccessible buckets:")
	for i, a := range state.allAccess {
		var caps []string
		if a.CanList {
			caps = append(caps, "LIST")
		}
		if a.CanPut {
			caps = append(caps, "PUT")
		}
		if a.CanGet {
			caps = append(caps, "GET")
		}
		if a.CanDel {
			caps = append(caps, "DELETE")
		}
		capStr := strings.Join(caps, ", ")
		if capStr == "" {
			capStr = "accessible"
		}

		regionStr := ""
		if a.Region != "" {
			regionStr = " [" + a.Region + "]"
		}
		urlStr := ""
		if a.URL != "" {
			urlStr = " @ " + a.URL
		}

		marker := "  "
		if state.activeAccess != nil && state.activeAccess.Bucket == a.Bucket &&
			state.activeAccess.Mode == a.Mode && state.activeAccess.URL == a.URL &&
			state.activeAccess.Region == a.Region {
			marker = "* "
		}
		fmt.Printf("  %s%d. %s (%s)%s%s  [%s]\n",
			marker, i+1, a.Bucket, a.Mode, regionStr, urlStr, capStr)
	}
	fmt.Println()
}

func shellUse(state *ShellState, args []string) {
	if len(args) == 0 {
		fmt.Println("Usage: use <bucket> [web|cli]  or  use <number>")
		return
	}

	// Try numeric selection
	if num, err := strconv.Atoi(args[0]); err == nil {
		idx := num - 1
		if idx >= 0 && idx < len(state.allAccess) {
			state.activeAccess = &state.allAccess[idx]
			state.activeBucket = state.activeAccess.Bucket
			state.cwdPrefix = ""
			fmt.Printf("Selected: %s (%s mode)\n", state.activeBucket, state.activeAccess.Mode)
			return
		}
		fmt.Printf("Invalid number. Use 1-%d.\n", len(state.allAccess))
		return
	}

	bucketName := args[0]
	modeFilter := ""
	if len(args) > 1 {
		modeFilter = strings.ToLower(args[1])
	}

	var matches []int
	for i, a := range state.allAccess {
		if a.Bucket == bucketName && (modeFilter == "" || a.Mode == modeFilter) {
			matches = append(matches, i)
		}
	}

	if len(matches) == 0 {
		fmt.Printf("Bucket '%s' not found in scan results.\n", bucketName)
		return
	}
	if len(matches) == 1 {
		state.activeAccess = &state.allAccess[matches[0]]
		state.activeBucket = state.activeAccess.Bucket
		state.cwdPrefix = ""
		fmt.Printf("Selected: %s (%s mode)\n", state.activeBucket, state.activeAccess.Mode)
		return
	}

	fmt.Printf("Multiple access entries for '%s':\n", bucketName)
	for _, idx := range matches {
		a := state.allAccess[idx]
		extra := ""
		if a.URL != "" {
			extra = " " + a.URL
		}
		if a.Region != "" {
			extra += " [" + a.Region + "]"
		}
		fmt.Printf("  %d. %s (%s)%s\n", idx+1, a.Bucket, a.Mode, extra)
	}
	fmt.Println("Use 'use <number>' to select one.")
}

func shellCd(state *ShellState, args []string) {
	if !requireActive(state) {
		return
	}
	if len(args) == 0 || args[0] == "/" {
		state.cwdPrefix = ""
		return
	}
	target := args[0]
	if target == ".." {
		p := strings.TrimRight(state.cwdPrefix, "/")
		idx := strings.LastIndex(p, "/")
		if idx < 0 {
			state.cwdPrefix = ""
		} else {
			state.cwdPrefix = p[:idx+1]
		}
		return
	}
	resolved := resolveKey(state, target)
	if !strings.HasSuffix(resolved, "/") {
		resolved += "/"
	}
	state.cwdPrefix = resolved
}

func shellPwd(state *ShellState) {
	if !requireActive(state) {
		return
	}
	fmt.Printf("s3://%s/%s\n", state.activeBucket, state.cwdPrefix)
}

// ── ls ──

func shellLs(state *ShellState, args []string) {
	if !requireActive(state) {
		return
	}
	prefix := state.cwdPrefix
	if len(args) > 0 {
		prefix = resolveKey(state, args[0])
		if prefix != "" && !strings.HasSuffix(prefix, "/") {
			prefix += "/"
		}
	}
	switch state.activeAccess.Mode {
	case "cli":
		shellLsCLI(state, prefix)
	case "web":
		shellLsWeb(state, prefix)
	}
}

func shellLsCLI(state *ShellState, prefix string) {
	a := state.activeAccess
	s3Path := "s3://" + a.Bucket + "/"
	if prefix != "" {
		s3Path += prefix
	}
	args := []string{"s3", "ls", s3Path, "--no-sign-request"}
	if a.Region != "" {
		args = append(args, "--region", a.Region)
	}
	out, err := exec.Command("aws", args...).CombinedOutput()
	if err != nil {
		fmt.Printf("Error: %s\n%s", err, string(out))
		return
	}
	fmt.Print(string(out))
}

func shellLsWeb(state *ShellState, prefix string) {
	a := state.activeAccess
	baseURL := strings.TrimRight(a.URL, "/")

	marker := ""
	for {
		q := "?list-type=2&delimiter=" + url.QueryEscape("/")
		if prefix != "" {
			q += "&prefix=" + url.QueryEscape(prefix)
		}
		if marker != "" {
			q += "&continuation-token=" + url.QueryEscape(marker)
		}

		status, body := httpFetch(baseURL + "/" + q)
		if status != 200 {
			// Fallback to v1
			q = "?delimiter=" + url.QueryEscape("/")
			if prefix != "" {
				q += "&prefix=" + url.QueryEscape(prefix)
			}
			if marker != "" {
				q += "&marker=" + url.QueryEscape(marker)
			}
			status, body = httpFetch(baseURL + "/" + q)
			if status != 200 {
				fmt.Printf("Error: HTTP %d\n%s\n", status, body)
				return
			}
		}

		var result ListBucketResult
		if err := xml.Unmarshal([]byte(body), &result); err != nil {
			fmt.Printf("Error parsing listing XML: %v\n", err)
			return
		}

		for _, cp := range result.CommonPrefixes {
			fmt.Printf("  PRE  %s\n", cp.Prefix)
		}
		for _, obj := range result.Contents {
			fmt.Printf("  %s  %10d  %s\n", obj.LastModified, obj.Size, obj.Key)
		}

		if !result.IsTruncated {
			break
		}
		marker = result.NextMarker
		if marker == "" && len(result.Contents) > 0 {
			marker = result.Contents[len(result.Contents)-1].Key
		}
		if marker == "" {
			break
		}
	}
}

// ── cat ──

func shellCat(state *ShellState, args []string) {
	if !requireActive(state) {
		return
	}
	if len(args) == 0 {
		fmt.Println("Usage: cat <key>")
		return
	}
	key := resolveKey(state, args[0])
	switch state.activeAccess.Mode {
	case "cli":
		shellCatCLI(state, key)
	case "web":
		shellCatWeb(state, key)
	}
}

func shellCatCLI(state *ShellState, key string) {
	a := state.activeAccess
	args := []string{"s3", "cp", "s3://" + a.Bucket + "/" + key, "-", "--no-sign-request"}
	if a.Region != "" {
		args = append(args, "--region", a.Region)
	}
	cmd := exec.Command("aws", args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		fmt.Printf("\nError: %v\n", err)
	}
	fmt.Println()
}

func shellCatWeb(state *ShellState, key string) {
	a := state.activeAccess
	objURL := strings.TrimRight(a.URL, "/") + "/" + s3KeyToURLPath(key)
	resp, err := httpClient.Get(objURL)
	if err != nil {
		fmt.Printf("Error: %v\n", err)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
		fmt.Printf("Error: HTTP %d\n%s\n", resp.StatusCode, string(body))
		return
	}
	_, _ = io.Copy(os.Stdout, resp.Body)
	fmt.Println()
}

// ── download ──

func shellDownload(state *ShellState, args []string) {
	if !requireActive(state) {
		return
	}
	if len(args) == 0 {
		fmt.Println("Usage: download <key> [local-path]")
		return
	}
	key := resolveKey(state, args[0])
	localPath := filepath.Base(key)
	if len(args) > 1 {
		localPath = args[1]
	}
	switch state.activeAccess.Mode {
	case "cli":
		shellDownloadCLI(state, key, localPath)
	case "web":
		shellDownloadWeb(state, key, localPath)
	}
}

func shellDownloadCLI(state *ShellState, key, localPath string) {
	a := state.activeAccess
	args := []string{"s3", "cp", "s3://" + a.Bucket + "/" + key, localPath, "--no-sign-request"}
	if a.Region != "" {
		args = append(args, "--region", a.Region)
	}
	out, err := exec.Command("aws", args...).CombinedOutput()
	if err != nil {
		fmt.Printf("Error: %v\n%s", err, string(out))
		return
	}
	fmt.Printf("Downloaded to: %s\n", localPath)
}

func shellDownloadWeb(state *ShellState, key, localPath string) {
	a := state.activeAccess
	objURL := strings.TrimRight(a.URL, "/") + "/" + s3KeyToURLPath(key)
	resp, err := httpClient.Get(objURL)
	if err != nil {
		fmt.Printf("Error: %v\n", err)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<16))
		fmt.Printf("Error: HTTP %d\n%s\n", resp.StatusCode, string(body))
		return
	}
	f, err := os.Create(localPath)
	if err != nil {
		fmt.Printf("Error creating file: %v\n", err)
		return
	}
	defer f.Close()
	n, err := io.Copy(f, resp.Body)
	if err != nil {
		fmt.Printf("Error writing file: %v\n", err)
		return
	}
	fmt.Printf("Downloaded %d bytes to: %s\n", n, localPath)
}

// ── upload ──

func shellUpload(state *ShellState, args []string) {
	if !requireActive(state) {
		return
	}
	if len(args) < 2 {
		fmt.Println("Usage: upload <local-path> <key>")
		return
	}
	localPath := args[0]
	key := resolveKey(state, args[1])
	if _, err := os.Stat(localPath); os.IsNotExist(err) {
		fmt.Printf("Local file not found: %s\n", localPath)
		return
	}
	switch state.activeAccess.Mode {
	case "cli":
		shellUploadCLI(state, localPath, key)
	case "web":
		shellUploadWeb(state, localPath, key)
	}
}

func shellUploadCLI(state *ShellState, localPath, key string) {
	a := state.activeAccess
	args := []string{"s3", "cp", localPath, "s3://" + a.Bucket + "/" + key, "--no-sign-request"}
	if a.Region != "" {
		args = append(args, "--region", a.Region)
	}
	out, err := exec.Command("aws", args...).CombinedOutput()
	if err != nil {
		fmt.Printf("Error: %v\n%s", err, string(out))
		return
	}
	fmt.Printf("Uploaded %s to s3://%s/%s\n", localPath, a.Bucket, key)
}

func shellUploadWeb(state *ShellState, localPath, key string) {
	a := state.activeAccess
	f, err := os.Open(localPath)
	if err != nil {
		fmt.Printf("Error opening file: %v\n", err)
		return
	}
	defer f.Close()

	objURL := strings.TrimRight(a.URL, "/") + "/" + s3KeyToURLPath(key)
	req, err := http.NewRequest("PUT", objURL, f)
	if err != nil {
		fmt.Printf("Error: %v\n", err)
		return
	}
	req.Header.Set("Content-Type", "application/octet-stream")
	if stat, serr := f.Stat(); serr == nil {
		req.ContentLength = stat.Size()
	}

	resp, err := httpClient.Do(req)
	if err != nil {
		fmt.Printf("Error: %v\n", err)
		return
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)

	if resp.StatusCode == 200 || resp.StatusCode == 201 || resp.StatusCode == 204 {
		fmt.Printf("Uploaded %s to s3://%s/%s\n", localPath, a.Bucket, key)
	} else {
		fmt.Printf("Upload failed: HTTP %d\n", resp.StatusCode)
	}
}

// ── rm ──

func shellRm(state *ShellState, args []string) {
	if !requireActive(state) {
		return
	}
	if len(args) == 0 {
		fmt.Println("Usage: rm <key>")
		return
	}
	key := resolveKey(state, args[0])
	switch state.activeAccess.Mode {
	case "cli":
		shellRmCLI(state, key)
	case "web":
		shellRmWeb(state, key)
	}
}

func shellRmCLI(state *ShellState, key string) {
	a := state.activeAccess
	args := []string{"s3", "rm", "s3://" + a.Bucket + "/" + key, "--no-sign-request"}
	if a.Region != "" {
		args = append(args, "--region", a.Region)
	}
	out, err := exec.Command("aws", args...).CombinedOutput()
	if err != nil {
		fmt.Printf("Error: %v\n%s", err, string(out))
		return
	}
	fmt.Printf("Deleted: s3://%s/%s\n", a.Bucket, key)
}

func shellRmWeb(state *ShellState, key string) {
	a := state.activeAccess
	objURL := strings.TrimRight(a.URL, "/") + "/" + s3KeyToURLPath(key)
	req, err := http.NewRequest("DELETE", objURL, nil)
	if err != nil {
		fmt.Printf("Error: %v\n", err)
		return
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		fmt.Printf("Error: %v\n", err)
		return
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)

	if resp.StatusCode == 200 || resp.StatusCode == 204 {
		fmt.Printf("Deleted: %s\n", key)
	} else {
		fmt.Printf("Delete failed: HTTP %d\n", resp.StatusCode)
	}
}

// ── head ──

func shellHead(state *ShellState, args []string) {
	if !requireActive(state) {
		return
	}
	if len(args) == 0 {
		fmt.Println("Usage: head <key>")
		return
	}
	key := resolveKey(state, args[0])
	switch state.activeAccess.Mode {
	case "cli":
		shellHeadCLI(state, key)
	case "web":
		shellHeadWeb(state, key)
	}
}

func shellHeadCLI(state *ShellState, key string) {
	a := state.activeAccess
	args := []string{"s3api", "head-object", "--bucket", a.Bucket, "--key", key, "--no-sign-request"}
	if a.Region != "" {
		args = append(args, "--region", a.Region)
	}
	out, err := exec.Command("aws", args...).CombinedOutput()
	if err != nil {
		fmt.Printf("Error: %v\n%s", err, string(out))
		return
	}
	fmt.Print(string(out))
}

func shellHeadWeb(state *ShellState, key string) {
	a := state.activeAccess
	objURL := strings.TrimRight(a.URL, "/") + "/" + s3KeyToURLPath(key)
	req, err := http.NewRequest("HEAD", objURL, nil)
	if err != nil {
		fmt.Printf("Error: %v\n", err)
		return
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		fmt.Printf("Error: %v\n", err)
		return
	}
	defer resp.Body.Close()

	fmt.Printf("HTTP %d\n", resp.StatusCode)
	for _, hdr := range []string{
		"Content-Type", "Content-Length", "Last-Modified",
		"ETag", "x-amz-server-side-encryption", "x-amz-storage-class",
		"x-amz-version-id", "Cache-Control", "Content-Disposition",
		"Content-Encoding",
	} {
		if v := resp.Header.Get(hdr); v != "" {
			fmt.Printf("  %s: %s\n", hdr, v)
		}
	}
}

// ────────────────────────── shared object helpers (mode-dispatched)

// listAllKeys returns every object key under prefix (recursive, no delimiter),
// using whichever backend the active bucket was discovered through.
func listAllKeys(a *BucketAccess, prefix string) ([]S3Object, error) {
	if a.Mode == "cli" {
		return listAllKeysCLI(a, prefix)
	}
	return listAllKeysWeb(a, prefix)
}

func listAllKeysCLI(a *BucketAccess, prefix string) ([]S3Object, error) {
	s3Path := "s3://" + a.Bucket + "/"
	if prefix != "" {
		s3Path += prefix
	}
	args := []string{"s3", "ls", s3Path, "--recursive", "--no-sign-request"}
	if a.Region != "" {
		args = append(args, "--region", a.Region)
	}
	out, err := exec.Command("aws", args...).CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("%v\n%s", err, string(out))
	}
	var objs []S3Object
	sc := bufio.NewScanner(bytes.NewReader(out))
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		if m := lsLineRe.FindStringSubmatch(sc.Text()); m != nil {
			size, _ := strconv.ParseInt(m[1], 10, 64)
			objs = append(objs, S3Object{Key: m[2], Size: size})
		}
	}
	return objs, nil
}

func listAllKeysWeb(a *BucketAccess, prefix string) ([]S3Object, error) {
	baseURL := strings.TrimRight(a.URL, "/")
	var objs []S3Object
	token := ""
	useV1 := false
	for {
		var q string
		if useV1 {
			q = "?"
			if prefix != "" {
				q += "prefix=" + url.QueryEscape(prefix) + "&"
			}
			if token != "" {
				q += "marker=" + url.QueryEscape(token) + "&"
			}
		} else {
			q = "?list-type=2"
			if prefix != "" {
				q += "&prefix=" + url.QueryEscape(prefix)
			}
			if token != "" {
				q += "&continuation-token=" + url.QueryEscape(token)
			}
		}

		status, body := httpFetchLimit(baseURL+"/"+q, 16<<20)
		if status != 200 {
			if !useV1 { // retry once with the older list API
				useV1 = true
				token = ""
				continue
			}
			return objs, fmt.Errorf("HTTP %d", status)
		}

		var result ListBucketResult
		if err := xml.Unmarshal([]byte(body), &result); err != nil {
			return objs, fmt.Errorf("parse listing: %v", err)
		}
		objs = append(objs, result.Contents...)

		if !result.IsTruncated {
			break
		}
		if useV1 {
			token = result.NextMarker
			if token == "" && len(result.Contents) > 0 {
				token = result.Contents[len(result.Contents)-1].Key
			}
		} else {
			token = result.NextContinuationToken
		}
		if token == "" {
			break
		}
	}
	return objs, nil
}

// fetchObject returns an object's bytes (up to limit bytes; limit <= 0 = unlimited).
func fetchObject(a *BucketAccess, key string, limit int64) ([]byte, error) {
	if a.Mode == "cli" {
		return fetchObjectCLI(a, key, limit)
	}
	return fetchObjectWeb(a, key, limit)
}

func fetchObjectCLI(a *BucketAccess, key string, limit int64) ([]byte, error) {
	args := []string{"s3", "cp", "s3://" + a.Bucket + "/" + key, "-", "--no-sign-request"}
	if a.Region != "" {
		args = append(args, "--region", a.Region)
	}
	cmd := exec.Command("aws", args...)
	var errBuf bytes.Buffer
	cmd.Stderr = &errBuf
	out, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("%v: %s", err, strings.TrimSpace(errBuf.String()))
	}
	if limit > 0 && int64(len(out)) > limit {
		out = out[:limit]
	}
	return out, nil
}

func fetchObjectWeb(a *BucketAccess, key string, limit int64) ([]byte, error) {
	objURL := strings.TrimRight(a.URL, "/") + "/" + s3KeyToURLPath(key)
	resp, err := httpClient.Get(objURL)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var r io.Reader = resp.Body
	if limit > 0 {
		r = io.LimitReader(resp.Body, limit)
	}
	body, _ := io.ReadAll(r)
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return body, nil
}

// uploadObject overwrites key with data via the active backend. S3 has no partial
// update, so callers fetch the whole object, modify it, then overwrite it here.
func uploadObject(a *BucketAccess, key string, data []byte) error {
	if a.Mode == "cli" {
		return uploadObjectCLI(a, key, data)
	}
	return uploadObjectWeb(a, key, data)
}

func uploadObjectCLI(a *BucketAccess, key string, data []byte) error {
	args := []string{"s3", "cp", "-", "s3://" + a.Bucket + "/" + key, "--no-sign-request"}
	if a.Region != "" {
		args = append(args, "--region", a.Region)
	}
	cmd := exec.Command("aws", args...)
	cmd.Stdin = bytes.NewReader(data)
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("%v\n%s", err, string(out))
	}
	return nil
}

func uploadObjectWeb(a *BucketAccess, key string, data []byte) error {
	objURL := strings.TrimRight(a.URL, "/") + "/" + s3KeyToURLPath(key)
	req, err := http.NewRequest("PUT", objURL, bytes.NewReader(data))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/octet-stream")
	req.ContentLength = int64(len(data))
	resp, err := httpClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	if resp.StatusCode == 200 || resp.StatusCode == 201 || resp.StatusCode == 204 {
		return nil
	}
	return fmt.Errorf("HTTP %d", resp.StatusCode)
}

// ────────────────────────── find / grep (search)

const maxGrepObjectSize = 10 << 20 // skip objects larger than this when grepping

// resolveSearchPrefix picks the prefix to search under: an explicit second arg,
// otherwise the current working prefix.
func resolveSearchPrefix(state *ShellState, args []string) string {
	prefix := state.cwdPrefix
	if len(args) > 1 {
		prefix = resolveKey(state, args[1])
		if prefix != "" && !strings.HasSuffix(prefix, "/") {
			prefix += "/"
		}
	}
	return prefix
}

func shellFind(state *ShellState, args []string) {
	if !requireActive(state) {
		return
	}
	if len(args) == 0 {
		fmt.Println("Usage: find <substring> [prefix]   (case-insensitive match on object keys)")
		return
	}
	keys, err := listAllKeys(state.activeAccess, resolveSearchPrefix(state, args))
	if err != nil {
		fmt.Printf("Error listing objects: %v\n", err)
		return
	}
	needle := strings.ToLower(args[0])
	count := 0
	for _, o := range keys {
		if strings.Contains(strings.ToLower(o.Key), needle) {
			fmt.Printf("  %10d  %s\n", o.Size, o.Key)
			count++
		}
	}
	fmt.Printf("%d match(es) out of %d object(s).\n", count, len(keys))
}

func shellGrep(state *ShellState, args []string) {
	if !requireActive(state) {
		return
	}
	if len(args) == 0 {
		fmt.Println("Usage: grep <regexp> [prefix]   (case-insensitive search inside object contents)")
		return
	}
	re, err := regexp.Compile("(?i)" + args[0])
	if err != nil {
		fmt.Printf("Invalid pattern: %v\n", err)
		return
	}
	keys, err := listAllKeys(state.activeAccess, resolveSearchPrefix(state, args))
	if err != nil {
		fmt.Printf("Error listing objects: %v\n", err)
		return
	}

	a := state.activeAccess
	matches, scanned, skipped := 0, 0, 0
	for i, o := range keys {
		fmt.Fprintf(os.Stdout, "\r%-80s\r[%d/%d] grep...", "", i+1, len(keys))
		if o.Size > maxGrepObjectSize {
			skipped++
			continue
		}
		data, err := fetchObject(a, o.Key, maxGrepObjectSize)
		if err != nil {
			continue
		}
		if bytes.IndexByte(data, 0) >= 0 { // skip binary blobs
			skipped++
			continue
		}
		scanned++
		sc := bufio.NewScanner(bytes.NewReader(data))
		sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
		ln := 0
		for sc.Scan() {
			ln++
			if re.MatchString(sc.Text()) {
				fmt.Fprintf(os.Stdout, "\r%-80s\r", "")
				fmt.Printf("%s:%d: %s\n", o.Key, ln, strings.TrimSpace(sc.Text()))
				matches++
			}
		}
	}
	fmt.Fprintf(os.Stdout, "\r%-80s\r", "")
	fmt.Printf("%d match(es); scanned %d object(s), skipped %d (binary/oversized).\n", matches, scanned, skipped)
}

// ────────────────────────── edit / replace (read-modify-write)

func shellEdit(state *ShellState, args []string) {
	if !requireActive(state) {
		return
	}
	if len(args) == 0 {
		fmt.Println("Usage: edit <key>   (opens $EDITOR, then overwrites the object on save)")
		return
	}
	a := state.activeAccess
	key := resolveKey(state, args[0])

	data, err := fetchObject(a, key, 0)
	if err != nil {
		fmt.Printf("Error fetching %s: %v\n", key, err)
		return
	}

	tmpFile := filepath.Join(tmpDir, "edit_"+filepath.Base(key))
	if err := os.WriteFile(tmpFile, data, 0644); err != nil {
		fmt.Printf("Error writing temp file: %v\n", err)
		return
	}
	defer os.Remove(tmpFile)

	editor := os.Getenv("EDITOR")
	if editor == "" {
		editor = os.Getenv("VISUAL")
	}
	if editor == "" {
		editor = "vi"
	}
	edParts := strings.Fields(editor)
	cmd := exec.Command(edParts[0], append(edParts[1:], tmpFile)...)
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
	if err := cmd.Run(); err != nil {
		fmt.Printf("Editor exited with error: %v\n", err)
		return
	}

	newData, err := os.ReadFile(tmpFile)
	if err != nil {
		fmt.Printf("Error reading edited file: %v\n", err)
		return
	}
	if bytes.Equal(newData, data) {
		fmt.Println("No changes; nothing uploaded.")
		return
	}
	if err := uploadObject(a, key, newData); err != nil {
		fmt.Printf("Upload failed: %v\n", err)
		return
	}
	fmt.Printf("Saved %d bytes to s3://%s/%s (overwrote previous object).\n", len(newData), a.Bucket, key)
}

func shellReplace(state *ShellState, args []string) {
	if !requireActive(state) {
		return
	}
	if len(args) < 3 {
		fmt.Println("Usage: replace <key> <old> <new>   (old/new are single whitespace-free tokens)")
		return
	}
	a := state.activeAccess
	key := resolveKey(state, args[0])
	oldTok, newTok := args[1], args[2]

	data, err := fetchObject(a, key, 0)
	if err != nil {
		fmt.Printf("Error fetching %s: %v\n", key, err)
		return
	}
	n := bytes.Count(data, []byte(oldTok))
	if n == 0 {
		fmt.Printf("'%s' not found in %s; nothing changed.\n", oldTok, key)
		return
	}
	newData := bytes.ReplaceAll(data, []byte(oldTok), []byte(newTok))
	if err := uploadObject(a, key, newData); err != nil {
		fmt.Printf("Upload failed: %v\n", err)
		return
	}
	fmt.Printf("Replaced %d occurrence(s) of '%s' in s3://%s/%s.\n", n, oldTok, a.Bucket, key)
}

// ────────────────────────── shell command dispatch

func handleCommand(state *ShellState, line string) {
	parts := strings.Fields(line)
	if len(parts) == 0 {
		return
	}
	cmd := strings.ToLower(parts[0])
	args := parts[1:]

	switch cmd {
	case "help", "?":
		shellHelp()
	case "buckets":
		shellBuckets(state)
	case "use":
		shellUse(state, args)
	case "ls", "dir":
		shellLs(state, args)
	case "cd":
		shellCd(state, args)
	case "pwd":
		shellPwd(state)
	case "cat", "type":
		shellCat(state, args)
	case "download", "dl", "get":
		shellDownload(state, args)
	case "upload", "ul", "put":
		shellUpload(state, args)
	case "rm", "del", "delete":
		shellRm(state, args)
	case "head", "info":
		shellHead(state, args)
	case "find":
		shellFind(state, args)
	case "grep":
		shellGrep(state, args)
	case "edit":
		shellEdit(state, args)
	case "replace", "sed":
		shellReplace(state, args)
	default:
		fmt.Printf("Unknown command: %s. Type 'help' for available commands.\n", cmd)
	}
}

// ────────────────────────── shell loop

func runShell() {
	// Stop scan-phase signal handler, set up shell handler
	signal.Stop(sigCh)
	shellSigCh := make(chan os.Signal, 1)
	signal.Notify(shellSigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-shellSigCh
		fmt.Println("\nExiting shell.")
		os.RemoveAll(tmpDir)
		os.Exit(0)
	}()

	state := &ShellState{allAccess: accessList}

	// Auto-select if only one entry
	if len(accessList) == 1 {
		state.activeAccess = &accessList[0]
		state.activeBucket = state.activeAccess.Bucket
		fmt.Printf("\nAuto-selected bucket: %s (%s mode)\n", state.activeBucket, state.activeAccess.Mode)
	}

	fmt.Println("\n\033[1;36m=== Interactive Shell ===\033[0m")
	fmt.Println("Type 'help' for available commands, 'exit' or Ctrl+C to quit.")

	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)

	for {
		fmt.Print(buildPrompt(state))
		if !scanner.Scan() {
			break
		}
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		if line == "exit" || line == "quit" {
			fmt.Println("Bye.")
			return
		}
		handleCommand(state, line)
	}
}

// ────────────────────────── main

func main() {
	// ── register flags (short + long forms) ──
	flag.StringVar(&flagBucket, "b", "", "Single bucket name to check")
	flag.StringVar(&flagBucket, "bucket", "", "Single bucket name to check")
	flag.StringVar(&flagList, "l", "", "File containing list of bucket names (one per line)")
	flag.StringVar(&flagList, "list", "", "File containing list of bucket names (one per line)")
	flag.BoolVar(&flagWebOnly, "w", false, "Web checks only")
	flag.BoolVar(&flagWebOnly, "web-only", false, "Web checks only")
	flag.BoolVar(&flagCLIOnly, "c", false, "CLI checks only")
	flag.BoolVar(&flagCLIOnly, "cli-only", false, "CLI checks only")
	flag.BoolVar(&flagNameVar, "n", false, "Search for bucket name variations (dev-, -prod, etc.)")
	flag.BoolVar(&flagNameVar, "name-variations", false, "Search for bucket name variations")
	flag.BoolVar(&flagVerbose, "v", false, "Show all access attempts (verbose mode)")
	flag.BoolVar(&flagVerbose, "verbose", false, "Show all access attempts (verbose mode)")
	flag.IntVar(&flagThreads, "t", 30, "Concurrent threads for web checks (default: 30)")
	flag.IntVar(&flagThreads, "threads", 30, "Concurrent threads for web checks")

	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, `0xS3 – scan for publicly-listable S3 buckets across regions.

Usage:
  %[1]s -b examplebucket          # Check single bucket across all regions (default)
  %[1]s -b examplebucket -n       # Check bucket name variations across regions
  %[1]s -l buckets.txt -w         # Check all buckets from file (web checks only)
  %[1]s -l buckets.txt -c         # Check all buckets from file (CLI checks only)
  %[1]s -l buckets.txt -n -w      # Check all buckets from file with name variations
  %[1]s -b examplebucket -w       # Web checks only
  %[1]s -b examplebucket -c       # CLI checks only

Note: When using -l flag, -w or -c must be specified to prevent accidental resource-intensive scans.

Flags:
`, os.Args[0])
		flag.PrintDefaults()
	}
	flag.Parse()

	// ── validate inputs ──
	if flagBucket == "" && flagList == "" {
		fmt.Println("Error: Either -b or -l must be specified.")
		flag.Usage()
		os.Exit(1)
	}
	if flagBucket != "" && flagList != "" {
		fmt.Println("Error: -b and -l are mutually exclusive.")
		flag.Usage()
		os.Exit(1)
	}
	if flagWebOnly && flagCLIOnly {
		fmt.Println("Error: -w and -c are mutually exclusive.")
		os.Exit(1)
	}

	// ── load bucket names ──
	if flagBucket != "" {
		baseBuckets = []string{strings.TrimSpace(flagBucket)}
	} else {
		baseBuckets = loadBucketsFromFile(flagList)
	}
	baseName = baseBuckets[0]

	// ── validate -l requires -w or -c ──
	if flagList != "" && !flagWebOnly && !flagCLIOnly {
		fmt.Println("Error: When using -l/--list flag, you must specify either -w/--web-only or -c/--cli-only.")
		fmt.Println("This is required for bulk operations to prevent accidental resource-intensive scans.")
		fmt.Println("\nExamples:")
		fmt.Printf("  %s -l buckets.txt -w    # Web checks only\n", os.Args[0])
		fmt.Printf("  %s -l buckets.txt -c    # CLI checks only\n", os.Args[0])
		os.Exit(1)
	}

	doWeb = !flagCLIOnly
	doCLI = !flagWebOnly
	allVariations = buildVariations()

	// ── check AWS CLI availability ──
	if doCLI {
		if _, err := exec.LookPath("aws"); err != nil {
			fmt.Println("Error: AWS CLI not found. Install or use -w/--web-only.")
			os.Exit(1)
		}
	}

	// ── temp directory ──
	var err error
	tmpDir, err = os.MkdirTemp("", "s3chk_")
	if err != nil {
		fmt.Println("Error creating temp directory:", err)
		os.Exit(1)
	}
	testFilePath = filepath.Join(tmpDir, testFilename)
	defer os.RemoveAll(tmpDir)

	// ── HTTP client (skip TLS verification, matching Python behaviour) ──
	httpClient = &http.Client{
		Timeout: 15 * time.Second,
		Transport: &http.Transport{
			TLSClientConfig:     &tls.Config{InsecureSkipVerify: true},
			MaxIdleConns:        100,
			MaxIdleConnsPerHost: 10,
		},
	}

	// ── signal handling (first Ctrl-C = graceful, second = force) ──
	sigCh = make(chan os.Signal, 2)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigCh
		fmt.Println("\nSearch interrupted by user.")
		stopAll.Store(true)
		<-sigCh
		os.RemoveAll(tmpDir)
		os.Exit(130)
	}()

	// ── header ──
	fmt.Println("==== S3 Bucket Accessibility Check ====")
	if len(baseBuckets) == 1 {
		fmt.Printf("Base name: %s\n", baseName)
	} else {
		fmt.Printf("Input: %d buckets from file '%s'\n", len(baseBuckets), flagList)
		if flagVerbose {
			display := baseBuckets
			suffix := ""
			if len(display) > 5 {
				display = display[:5]
				suffix = "..."
			}
			fmt.Printf("Bucket names: %s%s\n", strings.Join(display, ", "), suffix)
		}
	}

	checkMode := "Both Web and CLI checks"
	if doCLI && !doWeb {
		checkMode = "CLI-only"
	} else if doWeb && !doCLI {
		checkMode = "Web-only"
	}
	varMode := fmt.Sprintf("exact names only (%d total)", len(allVariations))
	if flagNameVar {
		varMode = fmt.Sprintf("with name variations (%d total)", len(allVariations))
	}
	fmt.Printf("Mode: %s (%s)\n", checkMode, varMode)
	fmt.Printf("Regions to check: %d\n", len(awsRegions))
	if flagVerbose {
		fmt.Println("Verbose mode: ON")
	}

	// ── interactive test params ──
	getTestParams()

	// ── run checks ──
	if doCLI {
		runCLIChecks()
	}
	if doWeb {
		runWebChecks()
	}

	// ── summary ──
	// Determine which buckets have real capabilities vs just "exists (access denied)"
	usableBuckets := make(map[string]bool) // buckets with at least one working operation
	for _, a := range accessList {
		if a.CanList || a.CanPut || a.CanGet || a.CanDel {
			usableBuckets[a.Bucket] = true
		}
	}

	var accessibleBase, deniedBase []string
	for _, bkt := range baseBuckets {
		if _, ok := foundBuckets[bkt]; ok {
			if usableBuckets[bkt] {
				accessibleBase = append(accessibleBase, bkt)
			} else {
				deniedBase = append(deniedBase, bkt)
			}
		}
	}

	fmt.Println()
	if len(accessibleBase) > 0 {
		if len(baseBuckets) == 1 {
			fmt.Printf("Base bucket '\033[1;32m%s\033[0m' is accessible!\n", baseName)
		} else {
			fmt.Printf("Found %d accessible base bucket(s): \033[1;32m%s\033[0m\n", len(accessibleBase), strings.Join(accessibleBase, ", "))
		}
	}
	if len(deniedBase) > 0 {
		if len(baseBuckets) == 1 && len(accessibleBase) == 0 {
			fmt.Printf("Base bucket '\033[1;33m%s\033[0m' exists but access is denied (no operations succeeded).\n", baseName)
		} else {
			fmt.Printf("Found %d bucket(s) that exist but are access denied: \033[1;33m%s\033[0m\n", len(deniedBase), strings.Join(deniedBase, ", "))
		}
	}

	// Count additional variations beyond base buckets
	allFoundBase := len(accessibleBase) + len(deniedBase)
	if len(foundBuckets) > allFoundBase {
		additional := len(foundBuckets) - allFoundBase
		fmt.Printf("Found %d additional bucket variation(s).\n", additional)
	}

	if len(foundBuckets) == 0 {
		fmt.Println("No buckets found.")
	}

	if len(foundBuckets) > 0 && flagVerbose {
		fmt.Println("\nAll found buckets:")
		for bkt, regs := range foundBuckets {
			status := "\033[1;33m(access denied)\033[0m"
			if usableBuckets[bkt] {
				status = "\033[1;32m(accessible)\033[0m"
			}
			regionText := ""
			if len(regs) > 0 {
				sorted := make([]string, 0, len(regs))
				for r := range regs {
					sorted = append(sorted, r)
				}
				sort.Strings(sorted)
				regionText = fmt.Sprintf(" (regions: %s)", strings.Join(sorted, ", "))
			}
			fmt.Printf("  - %s %s%s\n", bkt, status, regionText)
		}
	}

	// ── interactive shell ──
	if len(accessList) > 0 {
		runShell()
	}
}
