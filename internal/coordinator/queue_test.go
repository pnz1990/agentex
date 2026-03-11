package coordinator

import (
	"testing"
)

func TestScoreIssue(t *testing.T) {
	tests := []struct {
		name   string
		labels []string
		want   int
	}{
		{
			name:   "single high-priority label",
			labels: []string{"collective-intelligence"},
			want:   10,
		},
		{
			name:   "multiple labels returns highest",
			labels: []string{"bug", "security", "documentation"},
			want:   9, // security = 9
		},
		{
			name:   "no matching labels returns default",
			labels: []string{"wontfix", "question"},
			want:   defaultVisionScore,
		},
		{
			name:   "empty labels returns default",
			labels: []string{},
			want:   defaultVisionScore,
		},
		{
			name:   "nil labels returns default",
			labels: nil,
			want:   defaultVisionScore,
		},
		{
			name:   "single low-priority label",
			labels: []string{"proliferation"},
			want:   1,
		},
		{
			name:   "mixed known and unknown labels",
			labels: []string{"unknown-label", "memory", "another-unknown"},
			want:   8, // memory = 8
		},
		{
			name:   "label with whitespace trimmed",
			labels: []string{" governance "},
			want:   9,
		},
		{
			name:   "two labels with same score",
			labels: []string{"security", "governance"},
			want:   9,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := ScoreIssue(tt.labels)
			if got != tt.want {
				t.Errorf("ScoreIssue(%v) = %d, want %d", tt.labels, got, tt.want)
			}
		})
	}
}

func TestSortQueue(t *testing.T) {
	tests := []struct {
		name       string
		issues     []int
		labelCache map[int][]string
		want       []int
	}{
		{
			name:   "sort by priority descending",
			issues: []int{100, 200, 300},
			labelCache: map[int][]string{
				100: {"documentation"},           // score 2
				200: {"collective-intelligence"}, // score 10
				300: {"security"},                // score 9
			},
			want: []int{200, 300, 100},
		},
		{
			name:   "stable sort preserves order for equal scores",
			issues: []int{10, 20, 30},
			labelCache: map[int][]string{
				10: {"bug"}, // score 4
				20: {"bug"}, // score 4
				30: {"bug"}, // score 4
			},
			want: []int{10, 20, 30},
		},
		{
			name:   "missing labels get default score",
			issues: []int{1, 2, 3},
			labelCache: map[int][]string{
				1: {"collective-intelligence"}, // score 10
				// 2 and 3 have no entries — default score 5
			},
			want: []int{1, 2, 3}, // 10, 5, 5
		},
		{
			name:       "empty issues",
			issues:     []int{},
			labelCache: map[int][]string{},
			want:       []int{},
		},
		{
			name:       "single issue",
			issues:     []int{42},
			labelCache: map[int][]string{42: {"bug"}},
			want:       []int{42},
		},
		{
			name:       "nil label cache",
			issues:     []int{1, 2},
			labelCache: nil,
			want:       []int{1, 2}, // both get default score 5, stable order preserved
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := SortQueue(tt.issues, tt.labelCache)
			if len(got) != len(tt.want) {
				t.Fatalf("SortQueue() returned %d elements, want %d", len(got), len(tt.want))
			}
			for i := range got {
				if got[i] != tt.want[i] {
					t.Errorf("SortQueue()[%d] = %d, want %d (full: %v)", i, got[i], tt.want[i], got)
					break
				}
			}
		})
	}
}

func TestSortQueueDoesNotMutateInput(t *testing.T) {
	original := []int{100, 200, 300}
	input := make([]int, len(original))
	copy(input, original)

	labelCache := map[int][]string{
		100: {"documentation"},           // 2
		200: {"collective-intelligence"}, // 10
		300: {"security"},                // 9
	}

	_ = SortQueue(input, labelCache)

	for i := range original {
		if input[i] != original[i] {
			t.Errorf("SortQueue mutated input: input[%d] = %d, original = %d", i, input[i], original[i])
		}
	}
}

func TestDeduplicateQueue(t *testing.T) {
	tests := []struct {
		name   string
		issues []int
		want   []int
	}{
		{
			name:   "with duplicates",
			issues: []int{1, 2, 3, 2, 1, 4},
			want:   []int{1, 2, 3, 4},
		},
		{
			name:   "no duplicates",
			issues: []int{5, 10, 15},
			want:   []int{5, 10, 15},
		},
		{
			name:   "all duplicates",
			issues: []int{7, 7, 7, 7},
			want:   []int{7},
		},
		{
			name:   "empty",
			issues: []int{},
			want:   []int{},
		},
		{
			name:   "nil",
			issues: nil,
			want:   nil,
		},
		{
			name:   "single element",
			issues: []int{42},
			want:   []int{42},
		},
		{
			name:   "preserves first occurrence order",
			issues: []int{3, 1, 2, 1, 3},
			want:   []int{3, 1, 2},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := DeduplicateQueue(tt.issues)
			if len(got) != len(tt.want) {
				t.Fatalf("DeduplicateQueue(%v) = %v (len %d), want %v (len %d)",
					tt.issues, got, len(got), tt.want, len(tt.want))
			}
			for i := range got {
				if got[i] != tt.want[i] {
					t.Errorf("DeduplicateQueue(%v)[%d] = %d, want %d",
						tt.issues, i, got[i], tt.want[i])
				}
			}
		})
	}
}

func TestMergeQueues(t *testing.T) {
	tests := []struct {
		name        string
		visionQueue []string
		taskQueue   []int
		want        []int
	}{
		{
			name:        "vision items first",
			visionQueue: []string{"42", "99"},
			taskQueue:   []int{100, 200},
			want:        []int{42, 99, 100, 200},
		},
		{
			name:        "dedup across queues",
			visionQueue: []string{"42"},
			taskQueue:   []int{42, 100},
			want:        []int{42, 100},
		},
		{
			name:        "no vision items",
			visionQueue: []string{},
			taskQueue:   []int{1, 2, 3},
			want:        []int{1, 2, 3},
		},
		{
			name:        "nil vision queue",
			visionQueue: nil,
			taskQueue:   []int{10, 20},
			want:        []int{10, 20},
		},
		{
			name:        "no task items",
			visionQueue: []string{"42"},
			taskQueue:   []int{},
			want:        []int{42},
		},
		{
			name:        "both empty",
			visionQueue: []string{},
			taskQueue:   []int{},
			want:        nil, // MergeQueues returns nil when nothing is added
		},
		{
			name:        "structured vision entries skipped",
			visionQueue: []string{"feature:test:ts:agent", "42", "feature:other:ts:agent"},
			taskQueue:   []int{100},
			want:        []int{42, 100},
		},
		{
			name:        "vision entries with whitespace",
			visionQueue: []string{" 42 ", "99"},
			taskQueue:   []int{100},
			want:        []int{42, 99, 100},
		},
		{
			name:        "empty string entries in vision queue",
			visionQueue: []string{"", "42", ""},
			taskQueue:   []int{100},
			want:        []int{42, 100},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := MergeQueues(tt.visionQueue, tt.taskQueue)
			if len(got) != len(tt.want) {
				t.Fatalf("MergeQueues() = %v (len %d), want %v (len %d)",
					got, len(got), tt.want, len(tt.want))
			}
			for i := range got {
				if got[i] != tt.want[i] {
					t.Errorf("MergeQueues()[%d] = %d, want %d (full: %v)",
						i, got[i], tt.want[i], got)
					break
				}
			}
		})
	}
}

func TestIsIssueBlocked(t *testing.T) {
	assignments := map[string]int{
		"worker-1": 100,
		"worker-2": 200,
	}

	tests := []struct {
		name  string
		issue int
		want  bool
	}{
		{"assigned issue", 100, true},
		{"another assigned issue", 200, true},
		{"unassigned issue", 300, false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := IsIssueBlocked(tt.issue, assignments)
			if got != tt.want {
				t.Errorf("IsIssueBlocked(%d) = %v, want %v", tt.issue, got, tt.want)
			}
		})
	}

	t.Run("empty assignments", func(t *testing.T) {
		got := IsIssueBlocked(100, map[string]int{})
		if got {
			t.Error("IsIssueBlocked with empty assignments should return false")
		}
	})

	t.Run("nil assignments", func(t *testing.T) {
		got := IsIssueBlocked(100, nil)
		if got {
			t.Error("IsIssueBlocked with nil assignments should return false")
		}
	})
}

func TestFilterBlockedIssues(t *testing.T) {
	tests := []struct {
		name              string
		issues            []int
		activeAssignments map[string]int
		openPRs           map[int]bool
		want              []int
	}{
		{
			name:              "filters assigned issues",
			issues:            []int{100, 200, 300},
			activeAssignments: map[string]int{"worker-1": 200},
			openPRs:           map[int]bool{},
			want:              []int{100, 300},
		},
		{
			name:              "filters issues with open PRs",
			issues:            []int{100, 200, 300},
			activeAssignments: map[string]int{},
			openPRs:           map[int]bool{300: true},
			want:              []int{100, 200},
		},
		{
			name:              "filters both assigned and PR-open",
			issues:            []int{100, 200, 300, 400},
			activeAssignments: map[string]int{"worker-1": 200},
			openPRs:           map[int]bool{300: true},
			want:              []int{100, 400},
		},
		{
			name:              "nothing blocked",
			issues:            []int{100, 200},
			activeAssignments: map[string]int{},
			openPRs:           map[int]bool{},
			want:              []int{100, 200},
		},
		{
			name:              "all blocked",
			issues:            []int{100, 200},
			activeAssignments: map[string]int{"w1": 100},
			openPRs:           map[int]bool{200: true},
			want:              []int{},
		},
		{
			name:              "empty issues",
			issues:            []int{},
			activeAssignments: map[string]int{"w1": 100},
			openPRs:           map[int]bool{200: true},
			want:              []int{},
		},
		{
			name:              "nil issues",
			issues:            nil,
			activeAssignments: map[string]int{},
			openPRs:           map[int]bool{},
			want:              nil,
		},
		{
			name:              "nil assignments and PRs",
			issues:            []int{100, 200},
			activeAssignments: nil,
			openPRs:           nil,
			want:              []int{100, 200},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := FilterBlockedIssues(tt.issues, tt.activeAssignments, tt.openPRs)
			if len(got) != len(tt.want) {
				t.Fatalf("FilterBlockedIssues() = %v (len %d), want %v (len %d)",
					got, len(got), tt.want, len(tt.want))
			}
			for i := range got {
				if got[i] != tt.want[i] {
					t.Errorf("FilterBlockedIssues()[%d] = %d, want %d",
						i, got[i], tt.want[i])
				}
			}
		})
	}
}
