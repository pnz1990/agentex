//go:build e2e

package harness

import (
	"context"
	"fmt"
	"testing"

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// buildMockAgentJob constructs a Kubernetes Job spec for a flight-test agent.
// The Job runs the agentex-agent binary with AGENTEX_FLIGHT_TEST=true,
// so it skips git clone and OpenCode, sleeps to simulate work, and posts
// a Report CR — exercising the full coordinator lifecycle without real LLM calls.
func buildMockAgentJob(agentName, taskCRName, role, namespace, image string, sleepSeconds int, failStr string) *batchv1.Job {
	backoffLimit := int32(0)
	sleepStr := fmt.Sprintf("%d", sleepSeconds)

	return &batchv1.Job{
		ObjectMeta: metav1.ObjectMeta{
			Name:      agentName,
			Namespace: namespace,
			Labels: map[string]string{
				"agentex/role":        role,
				"agentex/e2e":         "true",
				"agentex/flight-test": "true",
			},
		},
		Spec: batchv1.JobSpec{
			BackoffLimit: &backoffLimit,
			Template: corev1.PodTemplateSpec{
				ObjectMeta: metav1.ObjectMeta{
					Labels: map[string]string{
						"agentex/role":        role,
						"agentex/e2e":         "true",
						"agentex/flight-test": "true",
					},
				},
				Spec: corev1.PodSpec{
					RestartPolicy:      corev1.RestartPolicyNever,
					ServiceAccountName: "agentex-agent-sa",
					Containers: []corev1.Container{
						{
							Name:  "agent",
							Image: image,
							// Always pull to ensure the latest e2e image is used.
							ImagePullPolicy: corev1.PullAlways,
							// Use the bash entrypoint with AGENTEX_USE_GO=true which execs
							// /usr/local/bin/agentex-agent — the compiled Go binary.
							// No explicit Command override: the image ENTRYPOINT is entrypoint.sh.
							Env: []corev1.EnvVar{
								{Name: "AGENT_NAME", Value: agentName},
								{Name: "AGENT_ROLE", Value: role},
								{Name: "TASK_CR_NAME", Value: taskCRName},
								{Name: "NAMESPACE", Value: namespace},
								{Name: "AGENTEX_USE_GO", Value: "true"},
								{Name: "AGENTEX_FLIGHT_TEST", Value: "true"},
								{Name: "AGENTEX_COORDINATOR_SPAWNS", Value: "true"},
								{Name: "MOCK_AGENT_SLEEP_SECONDS", Value: sleepStr},
								{Name: "MOCK_AGENT_FAIL", Value: failStr},
							},
						},
					},
				},
			},
		},
	}
}

// BuildFlightJob constructs a Job with extra environment variables merged in.
// It delegates to buildMockAgentJob for the base spec, then appends extraEnv.
// Use this for scenario tests that need to set behavior flags like
// FLIGHT_THOUGHT_COUNT, FLIGHT_DEBATE_ENABLED, FLIGHT_MESSAGE_ENABLED, etc.
//
// S3 isolation: the job automatically inherits E2E_S3_PREFIX, S3_BUCKET, and
// AWS_REGION from the test environment (defaulting to "e2e/", "agentex-thoughts",
// and "us-west-2") so the pod writes to the same prefixed path that the test
// harness reads from.
func (c *Cluster) BuildFlightJob(agentName, taskCRName, role string, sleepSeconds int, fail bool, extraEnv map[string]string) *batchv1.Job {
	image := envOrDefault("FLIGHT_TEST_IMAGE", "569190534191.dkr.ecr.us-west-2.amazonaws.com/agentex/runner:e2e")
	failStr := "false"
	if fail {
		failStr = "true"
	}

	job := buildMockAgentJob(agentName, taskCRName, role, c.Namespace, image, sleepSeconds, failStr)

	// Inject S3 isolation env vars so the pod uses the same prefix as the harness.
	container := &job.Spec.Template.Spec.Containers[0]
	container.Env = append(container.Env,
		corev1.EnvVar{Name: "E2E_S3_PREFIX", Value: envOrDefault("E2E_S3_PREFIX", "e2e/")},
		corev1.EnvVar{Name: "S3_BUCKET", Value: envOrDefault("S3_BUCKET", "agentex-thoughts")},
		corev1.EnvVar{Name: "AWS_REGION", Value: envOrDefault("AWS_REGION", "us-west-2")},
	)

	// Append caller-supplied extra env vars (may override the S3 defaults above).
	for k, v := range extraEnv {
		container.Env = append(container.Env, corev1.EnvVar{Name: k, Value: v})
	}

	return job
}

// CreateCustomJob creates a pre-built Job in the test namespace.
// Use this with BuildFlightJob to create scenario jobs with extra env vars.
func (c *Cluster) CreateCustomJob(ctx context.Context, t *testing.T, job *batchv1.Job) {
	t.Helper()
	_, err := c.Client.Clientset.BatchV1().Jobs(c.Namespace).Create(ctx, job, metav1.CreateOptions{})
	if err != nil {
		t.Fatalf("create custom job %s: %v", job.Name, err)
	}
}
