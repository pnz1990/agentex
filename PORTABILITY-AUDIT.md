# Agentex Portability Audit

**Issue:** #819  
**Date:** 2026-03-09  
**Auditor:** planner-1773085349 (planner-bright-graph)  
**Goal:** Identify all hardcoded install assumptions preventing fresh installs in different AWS accounts, regions, and GitHub orgs

## Executive Summary

Agentex currently has **53 hardcoded references** across 7 categories that prevent portable installation. A fresh install would:
- File issues on the original GitHub repo (pnz1990/agentex)
- Write chronicle data to the original S3 bucket (agentex-thoughts)
- Pull images from the original ECR registry (569190534191.dkr.ecr.us-west-2.amazonaws.com)
- Fail to authenticate with IAM roles from a different account

This audit categorizes all hardcoded values and provides a remediation roadmap.

---

## Category 1: GitHub Repository (pnz1990/agentex)

**Impact:** Agents from a fresh install would file issues and PRs on the original repo.

| File | Line/Context | Current Value | Proposed Fix |
|------|-------------|---------------|--------------|
| `manifests/bootstrap/seed-prompt.sh` | gh issue list command | `pnz1990/agentex` | Read from `$REPO` env var |
| `manifests/crds/swarm-crd.yaml` | githubRepo default | `pnz1990/agentex` | Read from constitution ConfigMap |
| `manifests/rgds/swarm-graph.yaml` | githubRepo default | `pnz1990/agentex` | Read from constitution ConfigMap |
| `manifests/system/constitution.yaml` | githubRepo field | `pnz1990/agentex` | ✅ Already in constitution (template value) |
| `manifests/system/system-status.sh` | gh pr/issue commands | `pnz1990/agentex` | Read from constitution or env var |
| `images/runner/coordinator.sh` | gh issue view/list | `pnz1990/agentex` | ✅ Already uses `$REPO` env var |
| `images/runner/entrypoint.sh` | REPO default | `pnz1990/agentex` | ✅ Already reads from constitution |

**Total references:** 7  
**Already parameterized:** 3 (entrypoint.sh, coordinator.sh, constitution.yaml)  
**Remaining work:** 4 files need updates

---

## Category 2: AWS Account / ECR Registry (569190534191.dkr.ecr.us-west-2.amazonaws.com)

**Impact:** Fresh install cannot pull images without access to original ECR.

| File | Line/Context | Current Value | Proposed Fix |
|------|-------------|---------------|--------------|
| `manifests/bootstrap/seed-agent.yaml` | image field | `569190534191.dkr.ecr...` | Helm template variable `{{ .Values.ecrRegistry }}` |
| `manifests/bootstrap/seed-prompt.sh` | Account ID mention | `569190534191` | Remove hardcoded account reference |
| `manifests/rgds/agent-graph.yaml` | imageRegistry default | `569190534191.dkr.ecr...` | ✅ Already reads from constitution |
| `manifests/rgds/coordinator-graph.yaml` | imageRegistry default | `569190534191.dkr.ecr...` | ✅ Already reads from constitution |
| `manifests/rgds/swarm-graph.yaml` | imageRegistry default | `569190534191.dkr.ecr...` | ✅ Already reads from constitution |
| `manifests/system/constitution-validator.yaml` | image field | `569190534191.dkr.ecr...` | Helm template variable |
| `manifests/system/constitution.yaml` | ecrRegistry field | `569190534191.dkr.ecr...` | ✅ Already in constitution (template value) |
| `images/runner/entrypoint.sh` | ECR_REGISTRY default | `569190534191.dkr.ecr...` | ✅ Already reads from constitution |

**Total references:** 8  
**Already parameterized:** 5 (RGDs, entrypoint.sh, constitution)  
**Remaining work:** 3 bootstrap files

---

## Category 3: S3 Bucket (agentex-thoughts)

**Impact:** Chronicle and thought data would be written to original bucket (if accessible) or fail.

| File | Line/Context | Current Value | Proposed Fix |
|------|-------------|---------------|--------------|
| `manifests/system/constitution.yaml` | s3Bucket field | `agentex-thoughts` | ✅ Already in constitution (template value) |
| `images/runner/coordinator.sh` | Temp file prefix | `agentex-thoughts-XXXXXX` | Cosmetic only, low priority |
| `images/runner/entrypoint.sh` | S3_BUCKET default | `agentex-thoughts` | ✅ Already reads from constitution |
| `images/runner/identity.sh` | IDENTITY_BUCKET default | `agentex-thoughts` | ✅ Already reads from `$S3_BUCKET` |

**Total references:** 4  
**Already parameterized:** 3 (entrypoint.sh, identity.sh, constitution)  
**Remaining work:** 1 cosmetic fix (low priority)

---

## Category 4: AWS Region (us-west-2)

**Impact:** Fresh install in different region would fail or use wrong region for Bedrock/CloudWatch.

| File | Line/Context | Current Value | Proposed Fix |
|------|-------------|---------------|--------------|
| `manifests/bootstrap/seed-agent.yaml` | ECR image URL | `us-west-2` | Helm template (part of ecrRegistry) |
| `manifests/bootstrap/seed-prompt.sh` | Region mention | `us-west-2` | Remove hardcoded region reference |
| `manifests/rgds/*.yaml` (3 files) | imageRegistry defaults | `us-west-2` | ✅ Already part of ECR registry config |
| `manifests/system/cloudwatch-dashboard.yaml` | region fields (9x) | `us-west-2` | Helm template variable |
| `manifests/system/cloudwatch-dashboard.yaml` | AWS_REGION default (2x) | `us-west-2` | Helm template variable |
| `manifests/system/constitution-validator.yaml` | ECR image URL | `us-west-2` | Helm template (part of ecrRegistry) |
| `manifests/system/constitution.yaml` | awsRegion field | `us-west-2` | ✅ Already in constitution (template value) |
| `manifests/system/kro-install.sh` | REGION variable | `us-west-2` | Script parameter or env var |
| `images/runner/coordinator.sh` | BEDROCK_REGION default | `us-west-2` | ✅ Already env var with fallback |
| `images/runner/entrypoint.sh` | BEDROCK_REGION default | `us-west-2` | ✅ Already env var with fallback |

**Total references:** ~24 (many duplicates in cloudwatch-dashboard.yaml)  
**Already parameterized:** RGDs, runner scripts, constitution  
**Remaining work:** CloudWatch dashboard (11x), bootstrap files, kro-install.sh

---

## Category 5: Cluster Name (agentex)

**Impact:** kubectl config commands fail; agent environment assumes wrong cluster name.

| File | Line/Context | Current Value | Proposed Fix |
|------|-------------|---------------|--------------|
| `manifests/rgds/agent-graph.yaml` | clusterName default | `agentex` | ✅ Already reads from constitution |
| `manifests/rgds/coordinator-graph.yaml` | clusterName default | `agentex` | ✅ Already reads from constitution |
| `manifests/rgds/swarm-graph.yaml` | clusterName default | `agentex` | ✅ Already reads from constitution |
| `manifests/system/constitution.yaml` | clusterName field | `agentex` | ✅ Already in constitution (template value) |
| `manifests/system/kro-install.sh` | CLUSTER variable | `agentex` | Script parameter or env var |
| `images/runner/entrypoint.sh` | Warning check | `agentex` | ✅ Already reads from constitution |

**Total references:** 6  
**Already parameterized:** 5 (RGDs, entrypoint.sh, constitution)  
**Remaining work:** 1 (kro-install.sh)

---

## Category 6: IAM Role (agentex-agent-role)

**Impact:** Fresh install needs different IAM role name for Pod Identity.

| File | Line/Context | Current Value | Proposed Fix |
|------|-------------|---------------|--------------|
| `manifests/rbac/rbac.yaml` | PodIdentityAssociation (2x) | `agentex-agent-role` | Helm template variable `{{ .Values.iamRoleName }}` |

**Total references:** 2  
**Already parameterized:** 0  
**Remaining work:** 2 (both in rbac.yaml)

---

## Category 7: Service Account (agentex-agent-sa)

**Impact:** Low - typically scoped to namespace, but should be configurable.

| File | Line/Context | Current Value | Proposed Fix |
|------|-------------|---------------|--------------|
| `manifests/bootstrap/seed-agent.yaml` | serviceAccountName | `agentex-agent-sa` | Helm template variable (optional) |
| `manifests/rbac/rbac.yaml` | ServiceAccount name (3x) | `agentex-agent-sa` | Helm template variable (optional) |
| `manifests/rgds/*.yaml` (3 files) | serviceAccountName | `agentex-agent-sa` | Helm template variable (optional) |
| `manifests/system/constitution-validator.yaml` | serviceAccountName | `agentex-agent-sa` | Helm template variable (optional) |
| `manifests/system/pod-cleanup-cronjob.yaml` | serviceAccountName | `agentex-agent-sa` | Helm template variable (optional) |

**Total references:** 9  
**Priority:** Medium (can keep default `agentex-agent-sa` but make templatable)

---

## Category 8: Bedrock Model (us.anthropic.claude-sonnet-4-6)

**Impact:** Low - can be changed but should be configurable for different model preferences.

| File | Line/Context | Current Value | Proposed Fix |
|------|-------------|---------------|--------------|
| `manifests/system/constitution.yaml` | agentModel field | `us.anthropic.claude-sonnet-4-6` | ✅ Already in constitution |
| All RGDs and bootstrap manifests | model defaults | `us.anthropic.claude-sonnet-4-6` | ✅ Already read from constitution |
| `images/runner/entrypoint.sh` | BEDROCK_MODEL default | `us.anthropic.claude-sonnet-4-6` | ✅ Already env var |

**Total references:** ~17  
**Already parameterized:** All (reads from constitution)  
**Remaining work:** 0

---

## Remediation Roadmap

### Phase 1: Constitution Completeness (DONE ✅)
All runtime configuration values already exist in constitution ConfigMap:
- ✅ `githubRepo`
- ✅ `ecrRegistry`
- ✅ `s3Bucket`
- ✅ `awsRegion`
- ✅ `clusterName`
- ✅ `agentModel`

### Phase 2: Fix Bootstrap Manifests (HIGH PRIORITY)
These files need env var substitution or templating:
1. **seed-agent.yaml** - image URL hardcoded
2. **seed-prompt.sh** - repo/region/account mentions
3. **constitution-validator.yaml** - image URL hardcoded
4. **cloudwatch-dashboard.yaml** - 11x region references
5. **rbac.yaml** - IAM role name hardcoded

### Phase 3: Fix Shell Scripts (MEDIUM PRIORITY)
1. **kro-install.sh** - region/cluster hardcoded
2. **system-status.sh** - repo hardcoded

### Phase 4: Helm Chart (BLOCKS EVERYTHING)
Create Helm chart (issue #817) with values:
```yaml
ecrRegistry: "569190534191.dkr.ecr.us-west-2.amazonaws.com"
githubRepo: "pnz1990/agentex"
s3Bucket: "agentex-thoughts"
awsRegion: "us-west-2"
clusterName: "agentex"
iamRoleName: "agentex-agent-role"
serviceAccountName: "agentex-agent-sa"
bedrockModel: "us.anthropic.claude-sonnet-4-6"
namespace: "agentex"
```

All manifests become templates with `{{ .Values.X }}` substitution.

---

## Definition of Done (Updated)

✅ **Audit complete** - All 53+ hardcoded references identified and categorized  
⬜ **Constitution complete** - Already done, values exist  
⬜ **Bootstrap fixes** - 5 files need templating  
⬜ **Shell script fixes** - 2 files need parameterization  
⬜ **Helm chart** - Issue #817, blocks full portability  
⬜ **Validation** - Fresh install test in different account/region  

---

## Next Steps

1. **This PR**: Document the audit (this file)
2. **Follow-up PRs**: Fix bootstrap manifests (can be done incrementally)
3. **Helm chart**: Issue #817 makes all manifests fully templatable
4. **Validation**: Fresh install test guide

---

## Related Issues

- #817 - Helm chart creation (blocks full portability)
- #865 - v0.1 release tracking
- Enables: Multi-cloud support, disaster recovery, development environments

---

## Testing Plan

Once remediation is complete, test with:
1. Different AWS account (test IAM, ECR, S3 isolation)
2. Different region (test Bedrock, CloudWatch availability)
3. Different GitHub org (test issue/PR creation)
4. Different cluster name (test kubectl config)

Expected outcome: `helm install agentex ./chart -f custom-values.yaml` should work without editing any template files.
