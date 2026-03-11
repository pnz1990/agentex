package coordinator

import (
	"sort"
	"strconv"
	"strings"
)

// visionPriorityLabels maps GitHub issue labels to vision priority scores.
// Higher scores indicate higher priority. This matches the bash coordinator's
// VISION_PRIORITY_LABELS used for task queue sorting.
var visionPriorityLabels = map[string]int{
	"collective-intelligence": 10,
	"governance":              9,
	"security":                9,
	"identity":                8,
	"memory":                  8,
	"coordinator":             7,
	"self-improvement":        7,
	"enhancement":             5,
	"bug":                     4,
	"documentation":           2,
	"circuit-breaker":         1,
	"proliferation":           1,
}

// defaultVisionScore is the score assigned to issues with no matching labels.
const defaultVisionScore = 5

// ScoreIssue returns the highest vision priority score for the given labels.
// If no labels match any priority label, defaultVisionScore (5) is returned.
func ScoreIssue(labels []string) int {
	best := -1
	for _, label := range labels {
		label = strings.TrimSpace(label)
		if score, ok := visionPriorityLabels[label]; ok {
			if score > best {
				best = score
			}
		}
	}
	if best < 0 {
		return defaultVisionScore
	}
	return best
}

// SortQueue sorts issue numbers by their vision priority score in descending
// order. Issues with the same score retain their relative order (stable sort).
// The labelCache maps issue numbers to their GitHub labels.
func SortQueue(issues []int, labelCache map[int][]string) []int {
	if len(issues) <= 1 {
		return issues
	}

	// Work on a copy to avoid mutating the input.
	sorted := make([]int, len(issues))
	copy(sorted, issues)

	sort.SliceStable(sorted, func(i, j int) bool {
		scoreI := ScoreIssue(labelCache[sorted[i]])
		scoreJ := ScoreIssue(labelCache[sorted[j]])
		return scoreI > scoreJ
	})

	return sorted
}

// DeduplicateQueue removes duplicate issue numbers from the slice, preserving
// the order of first occurrence.
func DeduplicateQueue(issues []int) []int {
	if len(issues) == 0 {
		return issues
	}

	seen := make(map[int]struct{}, len(issues))
	result := make([]int, 0, len(issues))

	for _, issue := range issues {
		if _, exists := seen[issue]; !exists {
			seen[issue] = struct{}{}
			result = append(result, issue)
		}
	}

	return result
}

// MergeQueues merges the vision queue (governance-voted priorities) with the
// regular task queue. Vision items appear first, followed by task items.
// Duplicates across the two queues are removed (vision items take precedence).
//
// Vision queue entries may be plain issue numbers ("42") or structured entries
// ("feature:name:timestamp:agent"). Only plain integer entries are included
// as issue numbers; structured entries are skipped.
func MergeQueues(visionQueue []string, taskQueue []int) []int {
	var merged []int
	seen := make(map[int]struct{})

	// Vision items first — only include entries that are plain issue numbers.
	for _, entry := range visionQueue {
		entry = strings.TrimSpace(entry)
		if entry == "" {
			continue
		}
		n, err := strconv.Atoi(entry)
		if err != nil {
			// Structured entry (e.g. "feature:name:ts:agent") — skip.
			continue
		}
		if _, exists := seen[n]; !exists {
			seen[n] = struct{}{}
			merged = append(merged, n)
		}
	}

	// Task items second, skipping any already added from vision queue.
	for _, issue := range taskQueue {
		if _, exists := seen[issue]; !exists {
			seen[issue] = struct{}{}
			merged = append(merged, issue)
		}
	}

	return merged
}

// IsIssueBlocked returns true if the issue is already assigned to an active agent.
func IsIssueBlocked(issue int, activeAssignments map[string]int) bool {
	for _, assignedIssue := range activeAssignments {
		if assignedIssue == issue {
			return true
		}
	}
	return false
}

// FilterBlockedIssues removes issues that are already assigned to an agent or
// that have an open PR. The returned slice preserves the original order.
func FilterBlockedIssues(issues []int, activeAssignments map[string]int, openPRs map[int]bool) []int {
	if len(issues) == 0 {
		return issues
	}

	// Build a set of assigned issue numbers for O(1) lookup.
	assignedIssues := make(map[int]struct{}, len(activeAssignments))
	for _, issue := range activeAssignments {
		assignedIssues[issue] = struct{}{}
	}

	result := make([]int, 0, len(issues))
	for _, issue := range issues {
		if _, assigned := assignedIssues[issue]; assigned {
			continue
		}
		if openPRs[issue] {
			continue
		}
		result = append(result, issue)
	}

	return result
}
