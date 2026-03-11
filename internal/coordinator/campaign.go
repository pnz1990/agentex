package coordinator

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"time"

	k8sclient "github.com/pnz1990/agentex/internal/k8s"
)

// Campaign groups related tasks with dependency tracking and progress monitoring.
// Issues within a campaign can declare dependencies on other issues in the same
// campaign, enabling ordered execution of related work items.
type Campaign struct {
	Name         string         `json:"name"`
	Issues       []int          `json:"issues"`
	Dependencies map[int][]int  `json:"dependencies"` // issue -> depends on these issues
	Status       CampaignStatus `json:"status"`
	CreatedAt    time.Time      `json:"createdAt"`
	CreatedBy    string         `json:"createdBy"`
	CompletedAt  *time.Time     `json:"completedAt,omitempty"`
	Completed    map[int]bool   `json:"completed,omitempty"` // tracks per-issue completion
}

// CampaignStatus represents the lifecycle state of a campaign.
type CampaignStatus string

const (
	// CampaignActive means the campaign has unfinished issues.
	CampaignActive CampaignStatus = "active"
	// CampaignCompleted means all issues in the campaign are done.
	CampaignCompleted CampaignStatus = "completed"
	// CampaignStalled means no unblocked issues remain but the campaign is not complete.
	CampaignStalled CampaignStatus = "stalled"
)

// campaignsField is the coordinator-state ConfigMap field that stores campaigns.
const campaignsField = "campaigns"

// CampaignManager manages campaigns stored in the coordinator-state ConfigMap.
type CampaignManager struct {
	client    *k8sclient.Client
	namespace string
	logger    *slog.Logger
}

// NewCampaignManager creates a new CampaignManager.
func NewCampaignManager(client *k8sclient.Client, namespace string, logger *slog.Logger) *CampaignManager {
	return &CampaignManager{
		client:    client,
		namespace: namespace,
		logger:    logger,
	}
}

// CreateCampaign stores a new campaign in the coordinator-state ConfigMap.
// It appends the campaign to the existing campaigns list. If a campaign with
// the same name already exists, it returns an error.
func (cm *CampaignManager) CreateCampaign(ctx context.Context, campaign Campaign) error {
	existing, err := cm.GetCampaigns(ctx)
	if err != nil {
		return fmt.Errorf("loading existing campaigns: %w", err)
	}

	for _, c := range existing {
		if c.Name == campaign.Name {
			return fmt.Errorf("campaign %q already exists", campaign.Name)
		}
	}

	// Initialize completed map if nil
	if campaign.Completed == nil {
		campaign.Completed = make(map[int]bool)
	}

	existing = append(existing, campaign)
	return cm.saveCampaigns(ctx, existing)
}

// GetCampaigns loads all campaigns from the coordinator-state ConfigMap.
func (cm *CampaignManager) GetCampaigns(ctx context.Context) ([]Campaign, error) {
	configMap, err := cm.client.GetConfigMap(ctx, cm.namespace, StateConfigMapName)
	if err != nil {
		return nil, fmt.Errorf("getting coordinator state: %w", err)
	}

	raw, ok := configMap.Data[campaignsField]
	if !ok || raw == "" {
		return nil, nil
	}

	var campaigns []Campaign
	if err := json.Unmarshal([]byte(raw), &campaigns); err != nil {
		return nil, fmt.Errorf("unmarshaling campaigns: %w", err)
	}

	return campaigns, nil
}

// NextUnblockedIssue finds the next issue in the campaign that has all
// dependencies satisfied. It returns the issue number and true, or 0 and
// false if no unblocked issue is available.
func NextUnblockedIssue(campaign Campaign, completedIssues map[int]bool) (int, bool) {
	for _, issue := range campaign.Issues {
		// Skip already completed issues
		if completedIssues[issue] {
			continue
		}

		// Check if all dependencies are satisfied
		deps, hasDeps := campaign.Dependencies[issue]
		if !hasDeps {
			// No dependencies — this issue is unblocked
			return issue, true
		}

		allDepsMet := true
		for _, dep := range deps {
			if !completedIssues[dep] {
				allDepsMet = false
				break
			}
		}

		if allDepsMet {
			return issue, true
		}
	}

	return 0, false
}

// UpdateProgress marks an issue as completed within a campaign and updates
// the campaign status. If all issues are complete, the campaign is marked
// as completed. If no unblocked issues remain, it's marked as stalled.
func (cm *CampaignManager) UpdateProgress(ctx context.Context, campaignName string, completedIssue int) error {
	campaigns, err := cm.GetCampaigns(ctx)
	if err != nil {
		return fmt.Errorf("loading campaigns: %w", err)
	}

	found := false
	for i := range campaigns {
		if campaigns[i].Name != campaignName {
			continue
		}
		found = true

		if campaigns[i].Completed == nil {
			campaigns[i].Completed = make(map[int]bool)
		}
		campaigns[i].Completed[completedIssue] = true

		// Check if all issues are complete
		allDone := true
		for _, issue := range campaigns[i].Issues {
			if !campaigns[i].Completed[issue] {
				allDone = false
				break
			}
		}

		if allDone {
			now := time.Now().UTC()
			campaigns[i].CompletedAt = &now
			campaigns[i].Status = CampaignCompleted
			cm.logger.Info("campaign completed", "campaign", campaignName)
		} else {
			// Check for stall: no unblocked issues remain
			_, hasUnblocked := NextUnblockedIssue(campaigns[i], campaigns[i].Completed)
			if !hasUnblocked {
				campaigns[i].Status = CampaignStalled
				cm.logger.Warn("campaign stalled", "campaign", campaignName)
			} else {
				campaigns[i].Status = CampaignActive
			}
		}

		break
	}

	if !found {
		return fmt.Errorf("campaign %q not found", campaignName)
	}

	return cm.saveCampaigns(ctx, campaigns)
}

// FeedNextTask is reactive dispatch: when an issue completes, find it across
// all active campaigns and dispatch the next unblocked issue from each.
// Returns the list of issue numbers that are now unblocked and ready for dispatch.
func (cm *CampaignManager) FeedNextTask(ctx context.Context, completedIssue int) ([]int, error) {
	campaigns, err := cm.GetCampaigns(ctx)
	if err != nil {
		return nil, fmt.Errorf("loading campaigns: %w", err)
	}

	var unblocked []int

	for i := range campaigns {
		if campaigns[i].Status == CampaignCompleted {
			continue
		}

		// Check if this issue belongs to the campaign
		belongsToCampaign := false
		for _, issue := range campaigns[i].Issues {
			if issue == completedIssue {
				belongsToCampaign = true
				break
			}
		}

		if !belongsToCampaign {
			continue
		}

		// Mark the issue as completed in this campaign
		if campaigns[i].Completed == nil {
			campaigns[i].Completed = make(map[int]bool)
		}
		campaigns[i].Completed[completedIssue] = true

		// Update campaign status
		allDone := true
		for _, issue := range campaigns[i].Issues {
			if !campaigns[i].Completed[issue] {
				allDone = false
				break
			}
		}

		if allDone {
			now := time.Now().UTC()
			campaigns[i].CompletedAt = &now
			campaigns[i].Status = CampaignCompleted
			cm.logger.Info("campaign completed via FeedNextTask",
				"campaign", campaigns[i].Name,
			)
			continue
		}

		// Find the next unblocked issue
		next, ok := NextUnblockedIssue(campaigns[i], campaigns[i].Completed)
		if ok {
			unblocked = append(unblocked, next)
			cm.logger.Info("campaign dispatching next task",
				"campaign", campaigns[i].Name,
				"issue", next,
				"triggeredBy", completedIssue,
			)
		} else {
			campaigns[i].Status = CampaignStalled
			cm.logger.Warn("campaign stalled after completion",
				"campaign", campaigns[i].Name,
				"completedIssue", completedIssue,
			)
		}
	}

	// Save updated campaign state
	if err := cm.saveCampaigns(ctx, campaigns); err != nil {
		return nil, fmt.Errorf("saving campaigns after FeedNextTask: %w", err)
	}

	return unblocked, nil
}

// saveCampaigns serializes campaigns and writes them to the coordinator-state ConfigMap.
func (cm *CampaignManager) saveCampaigns(ctx context.Context, campaigns []Campaign) error {
	data, err := json.Marshal(campaigns)
	if err != nil {
		return fmt.Errorf("marshaling campaigns: %w", err)
	}

	patch := map[string]interface{}{
		"data": map[string]string{
			campaignsField: string(data),
		},
	}
	patchBytes, err := json.Marshal(patch)
	if err != nil {
		return fmt.Errorf("marshaling patch: %w", err)
	}

	_, err = cm.client.PatchConfigMap(ctx, cm.namespace, StateConfigMapName, patchBytes)
	if err != nil {
		return fmt.Errorf("patching campaigns field: %w", err)
	}

	return nil
}
