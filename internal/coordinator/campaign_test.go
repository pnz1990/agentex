package coordinator

import (
	"context"
	"log/slog"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"

	k8sclient "github.com/pnz1990/agentex/internal/k8s"
)

func newTestCampaignManager(t *testing.T, cm *corev1.ConfigMap) (*CampaignManager, *fake.Clientset) {
	t.Helper()
	fakeClient := fake.NewSimpleClientset(cm)
	logger := slog.Default()
	client := k8sclient.NewClientFromInterfaces(fakeClient, nil, logger)
	mgr := NewCampaignManager(client, "agentex", logger)
	return mgr, fakeClient
}

func makeCampaignStateCM(data map[string]string) *corev1.ConfigMap {
	return &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:            StateConfigMapName,
			Namespace:       "agentex",
			ResourceVersion: "1000",
			Labels: map[string]string{
				"agentex/component": "coordinator",
			},
		},
		Data: data,
	}
}

func TestNextUnblockedIssue_LinearDeps(t *testing.T) {
	// Linear chain: 1 -> 2 -> 3 (3 depends on 2, 2 depends on 1)
	campaign := Campaign{
		Name:   "linear",
		Issues: []int{1, 2, 3},
		Dependencies: map[int][]int{
			2: {1},
			3: {2},
		},
	}

	// Nothing completed: only issue 1 is unblocked
	issue, ok := NextUnblockedIssue(campaign, map[int]bool{})
	if !ok {
		t.Fatal("expected an unblocked issue")
	}
	if issue != 1 {
		t.Errorf("NextUnblockedIssue = %d, want 1", issue)
	}

	// Issue 1 completed: issue 2 is now unblocked
	issue, ok = NextUnblockedIssue(campaign, map[int]bool{1: true})
	if !ok {
		t.Fatal("expected an unblocked issue")
	}
	if issue != 2 {
		t.Errorf("NextUnblockedIssue = %d, want 2", issue)
	}

	// Issues 1,2 completed: issue 3 is now unblocked
	issue, ok = NextUnblockedIssue(campaign, map[int]bool{1: true, 2: true})
	if !ok {
		t.Fatal("expected an unblocked issue")
	}
	if issue != 3 {
		t.Errorf("NextUnblockedIssue = %d, want 3", issue)
	}
}

func TestNextUnblockedIssue_DiamondDeps(t *testing.T) {
	// Diamond: 4 depends on {2, 3}, both 2 and 3 depend on 1
	//
	//     1
	//    / \
	//   2   3
	//    \ /
	//     4
	campaign := Campaign{
		Name:   "diamond",
		Issues: []int{1, 2, 3, 4},
		Dependencies: map[int][]int{
			2: {1},
			3: {1},
			4: {2, 3},
		},
	}

	// Nothing completed: only issue 1 is unblocked
	issue, ok := NextUnblockedIssue(campaign, map[int]bool{})
	if !ok {
		t.Fatal("expected an unblocked issue")
	}
	if issue != 1 {
		t.Errorf("NextUnblockedIssue = %d, want 1", issue)
	}

	// Issue 1 completed: issues 2 and 3 are unblocked, returns first (2)
	issue, ok = NextUnblockedIssue(campaign, map[int]bool{1: true})
	if !ok {
		t.Fatal("expected an unblocked issue")
	}
	if issue != 2 {
		t.Errorf("NextUnblockedIssue = %d, want 2", issue)
	}

	// Issues 1,2 completed: issue 3 is unblocked (4 still blocked)
	issue, ok = NextUnblockedIssue(campaign, map[int]bool{1: true, 2: true})
	if !ok {
		t.Fatal("expected an unblocked issue")
	}
	if issue != 3 {
		t.Errorf("NextUnblockedIssue = %d, want 3", issue)
	}

	// Issues 1,2,3 completed: issue 4 is now unblocked
	issue, ok = NextUnblockedIssue(campaign, map[int]bool{1: true, 2: true, 3: true})
	if !ok {
		t.Fatal("expected an unblocked issue")
	}
	if issue != 4 {
		t.Errorf("NextUnblockedIssue = %d, want 4", issue)
	}
}

func TestNextUnblockedIssue_AllComplete(t *testing.T) {
	campaign := Campaign{
		Name:   "done",
		Issues: []int{1, 2, 3},
		Dependencies: map[int][]int{
			2: {1},
			3: {2},
		},
	}

	_, ok := NextUnblockedIssue(campaign, map[int]bool{1: true, 2: true, 3: true})
	if ok {
		t.Error("expected no unblocked issue when all are complete")
	}
}

func TestNextUnblockedIssue_NoneReady(t *testing.T) {
	// Circular dependency or unsatisfiable: issue 1 depends on 2, issue 2 depends on 1
	campaign := Campaign{
		Name:   "stuck",
		Issues: []int{1, 2},
		Dependencies: map[int][]int{
			1: {2},
			2: {1},
		},
	}

	_, ok := NextUnblockedIssue(campaign, map[int]bool{})
	if ok {
		t.Error("expected no unblocked issue with circular deps")
	}
}

func TestNextUnblockedIssue_NoDeps(t *testing.T) {
	campaign := Campaign{
		Name:         "parallel",
		Issues:       []int{10, 20, 30},
		Dependencies: map[int][]int{},
	}

	issue, ok := NextUnblockedIssue(campaign, map[int]bool{})
	if !ok {
		t.Fatal("expected an unblocked issue")
	}
	if issue != 10 {
		t.Errorf("NextUnblockedIssue = %d, want 10", issue)
	}
}

func TestCreateAndGetCampaigns(t *testing.T) {
	cm := makeCampaignStateCM(map[string]string{
		"bootstrapped": "true",
	})
	mgr, _ := newTestCampaignManager(t, cm)
	ctx := context.Background()

	campaign := Campaign{
		Name:   "test-campaign",
		Issues: []int{100, 200, 300},
		Dependencies: map[int][]int{
			200: {100},
			300: {200},
		},
		Status:    CampaignActive,
		CreatedAt: time.Date(2026, 3, 10, 12, 0, 0, 0, time.UTC),
		CreatedBy: "planner-1",
	}

	// Create
	err := mgr.CreateCampaign(ctx, campaign)
	if err != nil {
		t.Fatalf("CreateCampaign: %v", err)
	}

	// Get
	campaigns, err := mgr.GetCampaigns(ctx)
	if err != nil {
		t.Fatalf("GetCampaigns: %v", err)
	}
	if len(campaigns) != 1 {
		t.Fatalf("expected 1 campaign, got %d", len(campaigns))
	}

	got := campaigns[0]
	if got.Name != "test-campaign" {
		t.Errorf("Name = %q, want %q", got.Name, "test-campaign")
	}
	if len(got.Issues) != 3 {
		t.Errorf("Issues len = %d, want 3", len(got.Issues))
	}
	if got.Status != CampaignActive {
		t.Errorf("Status = %q, want %q", got.Status, CampaignActive)
	}
	if got.CreatedBy != "planner-1" {
		t.Errorf("CreatedBy = %q, want %q", got.CreatedBy, "planner-1")
	}

	// Verify dependencies round-tripped
	deps200 := got.Dependencies[200]
	if len(deps200) != 1 || deps200[0] != 100 {
		t.Errorf("Dependencies[200] = %v, want [100]", deps200)
	}
}

func TestCreateCampaign_DuplicateName(t *testing.T) {
	cm := makeCampaignStateCM(map[string]string{
		"bootstrapped": "true",
	})
	mgr, _ := newTestCampaignManager(t, cm)
	ctx := context.Background()

	campaign := Campaign{
		Name:      "dup-test",
		Issues:    []int{1},
		Status:    CampaignActive,
		CreatedAt: time.Now(),
	}

	if err := mgr.CreateCampaign(ctx, campaign); err != nil {
		t.Fatalf("first CreateCampaign: %v", err)
	}

	err := mgr.CreateCampaign(ctx, campaign)
	if err == nil {
		t.Fatal("expected error for duplicate campaign name")
	}
}

func TestGetCampaigns_Empty(t *testing.T) {
	cm := makeCampaignStateCM(map[string]string{
		"bootstrapped": "true",
	})
	mgr, _ := newTestCampaignManager(t, cm)

	campaigns, err := mgr.GetCampaigns(context.Background())
	if err != nil {
		t.Fatalf("GetCampaigns: %v", err)
	}
	if len(campaigns) != 0 {
		t.Errorf("expected 0 campaigns, got %d", len(campaigns))
	}
}

func TestUpdateProgress_Partial(t *testing.T) {
	cm := makeCampaignStateCM(map[string]string{
		"bootstrapped": "true",
	})
	mgr, _ := newTestCampaignManager(t, cm)
	ctx := context.Background()

	campaign := Campaign{
		Name:   "progress-test",
		Issues: []int{1, 2, 3},
		Dependencies: map[int][]int{
			2: {1},
			3: {2},
		},
		Status:    CampaignActive,
		CreatedAt: time.Now(),
	}
	if err := mgr.CreateCampaign(ctx, campaign); err != nil {
		t.Fatalf("CreateCampaign: %v", err)
	}

	// Complete issue 1
	if err := mgr.UpdateProgress(ctx, "progress-test", 1); err != nil {
		t.Fatalf("UpdateProgress: %v", err)
	}

	campaigns, err := mgr.GetCampaigns(ctx)
	if err != nil {
		t.Fatalf("GetCampaigns: %v", err)
	}
	if len(campaigns) != 1 {
		t.Fatalf("expected 1 campaign, got %d", len(campaigns))
	}

	got := campaigns[0]
	if got.Status != CampaignActive {
		t.Errorf("Status = %q, want %q (campaign not fully complete)", got.Status, CampaignActive)
	}
	if !got.Completed[1] {
		t.Error("issue 1 should be marked completed")
	}
	if got.CompletedAt != nil {
		t.Error("CompletedAt should be nil for partially completed campaign")
	}
}

func TestUpdateProgress_Complete(t *testing.T) {
	cm := makeCampaignStateCM(map[string]string{
		"bootstrapped": "true",
	})
	mgr, _ := newTestCampaignManager(t, cm)
	ctx := context.Background()

	campaign := Campaign{
		Name:         "complete-test",
		Issues:       []int{1, 2},
		Dependencies: map[int][]int{2: {1}},
		Status:       CampaignActive,
		CreatedAt:    time.Now(),
	}
	if err := mgr.CreateCampaign(ctx, campaign); err != nil {
		t.Fatalf("CreateCampaign: %v", err)
	}

	// Complete both issues
	if err := mgr.UpdateProgress(ctx, "complete-test", 1); err != nil {
		t.Fatalf("UpdateProgress(1): %v", err)
	}
	if err := mgr.UpdateProgress(ctx, "complete-test", 2); err != nil {
		t.Fatalf("UpdateProgress(2): %v", err)
	}

	campaigns, err := mgr.GetCampaigns(ctx)
	if err != nil {
		t.Fatalf("GetCampaigns: %v", err)
	}

	got := campaigns[0]
	if got.Status != CampaignCompleted {
		t.Errorf("Status = %q, want %q", got.Status, CampaignCompleted)
	}
	if got.CompletedAt == nil {
		t.Error("CompletedAt should be set for completed campaign")
	}
}

func TestUpdateProgress_NotFound(t *testing.T) {
	cm := makeCampaignStateCM(map[string]string{
		"bootstrapped": "true",
	})
	mgr, _ := newTestCampaignManager(t, cm)

	err := mgr.UpdateProgress(context.Background(), "nonexistent", 1)
	if err == nil {
		t.Fatal("expected error for nonexistent campaign")
	}
}

func TestFeedNextTask_TriggersDispatch(t *testing.T) {
	cm := makeCampaignStateCM(map[string]string{
		"bootstrapped": "true",
	})
	mgr, _ := newTestCampaignManager(t, cm)
	ctx := context.Background()

	// Create campaign: 1 -> 2 -> 3
	campaign := Campaign{
		Name:   "feed-test",
		Issues: []int{1, 2, 3},
		Dependencies: map[int][]int{
			2: {1},
			3: {2},
		},
		Status:    CampaignActive,
		CreatedAt: time.Now(),
	}
	if err := mgr.CreateCampaign(ctx, campaign); err != nil {
		t.Fatalf("CreateCampaign: %v", err)
	}

	// Complete issue 1 — should unblock issue 2
	unblocked, err := mgr.FeedNextTask(ctx, 1)
	if err != nil {
		t.Fatalf("FeedNextTask: %v", err)
	}
	if len(unblocked) != 1 {
		t.Fatalf("expected 1 unblocked issue, got %d", len(unblocked))
	}
	if unblocked[0] != 2 {
		t.Errorf("unblocked[0] = %d, want 2", unblocked[0])
	}

	// Complete issue 2 — should unblock issue 3
	unblocked, err = mgr.FeedNextTask(ctx, 2)
	if err != nil {
		t.Fatalf("FeedNextTask: %v", err)
	}
	if len(unblocked) != 1 {
		t.Fatalf("expected 1 unblocked issue, got %d", len(unblocked))
	}
	if unblocked[0] != 3 {
		t.Errorf("unblocked[0] = %d, want 3", unblocked[0])
	}

	// Complete issue 3 — campaign should be done, no more unblocked
	unblocked, err = mgr.FeedNextTask(ctx, 3)
	if err != nil {
		t.Fatalf("FeedNextTask: %v", err)
	}
	if len(unblocked) != 0 {
		t.Errorf("expected 0 unblocked issues after completion, got %d", len(unblocked))
	}

	// Verify campaign is completed
	campaigns, err := mgr.GetCampaigns(ctx)
	if err != nil {
		t.Fatalf("GetCampaigns: %v", err)
	}
	if campaigns[0].Status != CampaignCompleted {
		t.Errorf("Status = %q, want %q", campaigns[0].Status, CampaignCompleted)
	}
}

func TestFeedNextTask_UnrelatedIssue(t *testing.T) {
	cm := makeCampaignStateCM(map[string]string{
		"bootstrapped": "true",
	})
	mgr, _ := newTestCampaignManager(t, cm)
	ctx := context.Background()

	campaign := Campaign{
		Name:      "feed-unrelated",
		Issues:    []int{10, 20},
		Status:    CampaignActive,
		CreatedAt: time.Now(),
	}
	if err := mgr.CreateCampaign(ctx, campaign); err != nil {
		t.Fatalf("CreateCampaign: %v", err)
	}

	// Complete issue 999 — not in any campaign
	unblocked, err := mgr.FeedNextTask(ctx, 999)
	if err != nil {
		t.Fatalf("FeedNextTask: %v", err)
	}
	if len(unblocked) != 0 {
		t.Errorf("expected 0 unblocked for unrelated issue, got %d", len(unblocked))
	}
}

func TestFeedNextTask_DiamondDeps(t *testing.T) {
	cm := makeCampaignStateCM(map[string]string{
		"bootstrapped": "true",
	})
	mgr, _ := newTestCampaignManager(t, cm)
	ctx := context.Background()

	// Diamond: 4 depends on {2, 3}, both 2 and 3 depend on 1
	campaign := Campaign{
		Name:   "feed-diamond",
		Issues: []int{1, 2, 3, 4},
		Dependencies: map[int][]int{
			2: {1},
			3: {1},
			4: {2, 3},
		},
		Status:    CampaignActive,
		CreatedAt: time.Now(),
	}
	if err := mgr.CreateCampaign(ctx, campaign); err != nil {
		t.Fatalf("CreateCampaign: %v", err)
	}

	// Complete issue 1 — unblocks 2 (first unblocked in order)
	unblocked, err := mgr.FeedNextTask(ctx, 1)
	if err != nil {
		t.Fatalf("FeedNextTask(1): %v", err)
	}
	if len(unblocked) != 1 || unblocked[0] != 2 {
		t.Errorf("after completing 1, unblocked = %v, want [2]", unblocked)
	}

	// Complete issue 2 — unblocks 3 (4 still blocked on 3)
	unblocked, err = mgr.FeedNextTask(ctx, 2)
	if err != nil {
		t.Fatalf("FeedNextTask(2): %v", err)
	}
	if len(unblocked) != 1 || unblocked[0] != 3 {
		t.Errorf("after completing 2, unblocked = %v, want [3]", unblocked)
	}

	// Complete issue 3 — unblocks 4
	unblocked, err = mgr.FeedNextTask(ctx, 3)
	if err != nil {
		t.Fatalf("FeedNextTask(3): %v", err)
	}
	if len(unblocked) != 1 || unblocked[0] != 4 {
		t.Errorf("after completing 3, unblocked = %v, want [4]", unblocked)
	}
}
