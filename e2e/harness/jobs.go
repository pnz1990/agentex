//go:build e2e

package harness

import (
	"fmt"

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
