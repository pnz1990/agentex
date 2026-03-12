// Package s3 provides a thin S3 client wrapper for agentex agent behaviors.
//
// Implementation note: the agentex runner image has the AWS CLI v2 installed
// and IAM access is granted via EKS Pod Identity (agentex-agent-sa). Rather
// than vendoring the AWS SDK v2 (which would add ~15 MB to the vendor tree),
// we shell out to `aws s3api` / `aws s3` — exactly as the bash agents do via
// helpers.sh. This keeps the Go binary's dependency footprint minimal.
package s3

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"
)

// Client wraps AWS CLI S3 operations for the agentex agent.
type Client struct {
	bucket string
	prefix string
	region string
}

// NewClient creates an S3 client targeting the given bucket and key prefix.
// region is the AWS region (e.g. "us-west-2"). prefix is prepended to every
// key (e.g. "e2e/" for test isolation, "" for production).
func NewClient(bucket, prefix, region string) *Client {
	return &Client{
		bucket: bucket,
		prefix: prefix,
		region: region,
	}
}

// NewClientFromEnv creates an S3 client from environment variables.
// It reads S3_BUCKET, E2E_S3_PREFIX, and AWS_REGION (falling back to us-west-2).
func NewClientFromEnv() *Client {
	bucket := envOrDefault("S3_BUCKET", "agentex-thoughts")
	prefix := os.Getenv("E2E_S3_PREFIX") // empty in production
	region := envOrDefault("AWS_REGION", "us-west-2")
	return NewClient(bucket, prefix, region)
}

// PutJSON writes a Go value as JSON to s3://bucket/<prefix><key>.
// The key should NOT include the prefix (it is prepended automatically).
func (c *Client) PutJSON(ctx context.Context, key string, v interface{}) error {
	data, err := json.Marshal(v)
	if err != nil {
		return fmt.Errorf("marshal %s: %w", key, err)
	}
	return c.PutBytes(ctx, key, data, "application/json")
}

// PutBytes writes raw bytes to s3://bucket/<prefix><key>.
func (c *Client) PutBytes(ctx context.Context, key string, data []byte, contentType string) error {
	fullKey := c.fullKey(key)

	// Write to a temp file then use `aws s3api put-object`.
	// We avoid piping via stdin because the aws CLI requires a file path or
	// a seekable stream, and using a temp file is simpler and avoids shell quoting.
	tmp, err := os.CreateTemp("", "agentex-s3-*")
	if err != nil {
		return fmt.Errorf("creating temp file for %s: %w", key, err)
	}
	defer os.Remove(tmp.Name())

	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return fmt.Errorf("writing temp file for %s: %w", key, err)
	}
	tmp.Close()

	args := []string{
		"s3api", "put-object",
		"--bucket", c.bucket,
		"--key", fullKey,
		"--body", tmp.Name(),
	}
	if contentType != "" {
		args = append(args, "--content-type", contentType)
	}

	return c.runAWS(ctx, args...)
}

// GetJSON reads and unmarshals a JSON object from s3://bucket/<prefix><key> into v.
// Returns os.ErrNotExist if the key does not exist (NoSuchKey).
func (c *Client) GetJSON(ctx context.Context, key string, v interface{}) error {
	data, err := c.GetBytes(ctx, key)
	if err != nil {
		return err
	}
	return json.Unmarshal(data, v)
}

// GetBytes reads raw bytes from s3://bucket/<prefix><key>.
// Returns os.ErrNotExist if the key does not exist (NoSuchKey).
func (c *Client) GetBytes(ctx context.Context, key string) ([]byte, error) {
	fullKey := c.fullKey(key)

	tmp, err := os.CreateTemp("", "agentex-s3-get-*")
	if err != nil {
		return nil, fmt.Errorf("creating temp file for %s: %w", key, err)
	}
	tmpName := tmp.Name()
	tmp.Close()
	defer os.Remove(tmpName)

	args := []string{
		"s3api", "get-object",
		"--bucket", c.bucket,
		"--key", fullKey,
		tmpName,
	}

	if err := c.runAWS(ctx, args...); err != nil {
		if isS3NotFound(err) {
			return nil, fmt.Errorf("%w: s3://%s/%s", os.ErrNotExist, c.bucket, fullKey)
		}
		return nil, err
	}

	return os.ReadFile(tmpName)
}

// ListKeys lists all keys under s3://bucket/<prefix><keyPrefix>.
// The returned keys have the client prefix stripped.
func (c *Client) ListKeys(ctx context.Context, keyPrefix string) ([]string, error) {
	fullPrefix := c.fullKey(keyPrefix)

	type s3Contents struct {
		Key string `json:"Key"`
	}
	type s3ListResult struct {
		Contents []s3Contents `json:"Contents"`
	}

	var buf bytes.Buffer
	cmd := c.awsCmd(ctx,
		"s3api", "list-objects-v2",
		"--bucket", c.bucket,
		"--prefix", fullPrefix,
	)
	cmd.Stdout = &buf

	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("s3 list-objects %s: %w", fullPrefix, err)
	}

	var result s3ListResult
	if err := json.Unmarshal(buf.Bytes(), &result); err != nil {
		return nil, fmt.Errorf("parsing s3 list result: %w", err)
	}

	keys := make([]string, 0, len(result.Contents))
	for _, obj := range result.Contents {
		// Strip the client prefix from returned keys.
		k := strings.TrimPrefix(obj.Key, c.prefix)
		keys = append(keys, k)
	}
	return keys, nil
}

// DeletePrefix deletes all objects under s3://bucket/<prefix><keyPrefix>.
// Useful for e2e test cleanup.
func (c *Client) DeletePrefix(ctx context.Context, keyPrefix string) error {
	keys, err := c.ListKeys(ctx, keyPrefix)
	if err != nil {
		return fmt.Errorf("listing keys for delete: %w", err)
	}

	for _, key := range keys {
		fullKey := c.fullKey(key)
		if err := c.runAWS(ctx, "s3api", "delete-object", "--bucket", c.bucket, "--key", fullKey); err != nil {
			return fmt.Errorf("deleting %s: %w", fullKey, err)
		}
	}
	return nil
}

// KeyExists returns true if the given key exists in S3.
func (c *Client) KeyExists(ctx context.Context, key string) (bool, error) {
	_, err := c.GetBytes(ctx, key)
	if err != nil {
		if isErrNotExist(err) {
			return false, nil
		}
		return false, err
	}
	return true, nil
}

// --- helpers ---

func (c *Client) fullKey(key string) string {
	if c.prefix == "" {
		return key
	}
	// Avoid double-slash if key starts with prefix.
	if strings.HasPrefix(key, c.prefix) {
		return key
	}
	return c.prefix + key
}

func (c *Client) awsCmd(ctx context.Context, args ...string) *exec.Cmd {
	cmd := exec.CommandContext(ctx, "aws", args...)
	cmd.Env = append(os.Environ(), "AWS_DEFAULT_REGION="+c.region)
	return cmd
}

func (c *Client) runAWS(ctx context.Context, args ...string) error {
	var stderr bytes.Buffer
	cmd := c.awsCmd(ctx, args...)
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		return fmt.Errorf("aws %s: %w\nstderr: %s", strings.Join(args[:2], " "), err, stderr.String())
	}
	return nil
}

func isS3NotFound(err error) bool {
	return err != nil && strings.Contains(err.Error(), "NoSuchKey")
}

func isErrNotExist(err error) bool {
	return err != nil && (strings.Contains(err.Error(), "NoSuchKey") ||
		strings.Contains(err.Error(), os.ErrNotExist.Error()))
}

func envOrDefault(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

// S3PlanningState is the JSON structure written to S3 for planning state.
type S3PlanningState struct {
	AgentName   string    `json:"agentName"`
	Role        string    `json:"role"`
	CurrentWork string    `json:"currentWork"`
	N1Priority  string    `json:"n1Priority"`
	N2Priority  string    `json:"n2Priority"`
	Blockers    string    `json:"blockers"`
	Timestamp   time.Time `json:"timestamp"`
}

// S3SwarmMemory is the JSON structure written to S3 for swarm memory.
type S3SwarmMemory struct {
	SwarmName string    `json:"swarmName"`
	Goal      string    `json:"goal"`
	Members   []string  `json:"members"`
	Tasks     []string  `json:"tasks"`
	Decisions []string  `json:"decisions"`
	Origin    string    `json:"origin"`
	Timestamp time.Time `json:"timestamp"`
}

// S3Identity is the JSON structure written to S3 for agent identity.
type S3Identity struct {
	AgentName      string         `json:"agentName"`
	Role           string         `json:"role"`
	Specialization string         `json:"specialization"`
	Stats          map[string]int `json:"stats"`
	Timestamp      time.Time      `json:"timestamp"`
}

// S3Chronicle is the JSON structure for a chronicle candidate.
type S3Chronicle struct {
	Era       string    `json:"era"`
	Summary   string    `json:"summary"`
	Lesson    string    `json:"lesson"`
	Milestone bool      `json:"milestone"`
	Author    string    `json:"author"`
	Timestamp time.Time `json:"timestamp"`
}
