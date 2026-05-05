# Auto-Revert Workflow Setup

This document describes the setup required to activate the auto-revert-on-red workflow.

## Workflows Added

1. **`auto-revert-on-red.yml`** - Automatically reverts Ship to TestFlight failures on main
   - Trigger: Detects `Ship to TestFlight` workflow failure on main branch
   - Action: Creates revert commit → opens PR → auto-merges if CI passes
   - Fallback: Escalates as P0 incident if revert PR's own CI fails

2. **`verify-auto-revert.yml`** - Smoke test for validation
   - Trigger: Manual `workflow_dispatch` 
   - Action: Validates workflow syntax and simulates revert logic

## Required GitHub Secrets

Add these secrets to the vault-ios repository (Settings → Secrets and variables → Actions):

### 1. `FLEET_OPS_GH_APP_TOKEN`
- **Purpose**: GitHub App token for bypassing branch protections during auto-merge
- **Value**: Generate via `~/scripts/mint_gh_token.py katafract-io`
- **Used in**: auto-revert-on-red.yml step "Enable auto-merge on revert PR"

### 2. `MATRIX_WEBHOOK_FLEET_OPS`
- **Purpose**: Matrix room webhook for #fleet-ops notifications
- **Value**: Example: `https://matrix.example.com/_matrix/client/r0/rooms/...`
- **Used in**: 
  - auto-revert-on-red.yml steps: "Notify Matrix on success" and "Create incident on revert-PR CI failure"
  - Sends templated messages with revert details

## Testing

### Syntax Validation (Safe to run anytime)
```bash
gh workflow run verify-auto-revert.yml --ref feat/auto-revert-on-red -f test_mode=check-syntax
```

### Simulate Revert (Creates temporary test commit)
```bash
gh workflow run verify-auto-revert.yml --ref feat/auto-revert-on-red -f test_mode=simulate-failure
```

## Deployment Checklist

- [ ] Add `FLEET_OPS_GH_APP_TOKEN` secret to vault-ios repo
- [ ] Add `MATRIX_WEBHOOK_FLEET_OPS` secret to vault-ios repo
- [ ] Merge `feat/auto-revert-on-red` PR to main
- [ ] Verify by triggering syntax validation: `gh workflow run verify-auto-revert.yml`
- [ ] Test with a real Ship to TestFlight failure (or manual trigger)

## Acceptance Criteria (from OP #61)

- [x] PR opened with `auto-revert-on-red.yml` workflow
- [x] Workflow file syntax validates
- [x] Smoke test pattern provided (verify-auto-revert.yml)
- [ ] MATRIX_WEBHOOK_FLEET_OPS configured and tested
- [ ] FLEET_OPS_GH_APP_TOKEN configured
- [ ] Live test: Trigger known-failing main push; revert PR opens within 5 min

## Troubleshooting

**Q: Auto-merge not working?**
A: Verify FLEET_OPS_GH_APP_TOKEN is set and has `repo` scope. Ensure branch protection rules allow auto-merge.

**Q: No Matrix notification?**
A: Check MATRIX_WEBHOOK_FLEET_OPS secret is set correctly. Verify webhook URL is accessible from GitHub Actions runners.

**Q: Revert fails with merge conflict?**
A: This is expected when the failing commit has conflicts with subsequent changes. The workflow leaves the PR open for manual resolution and escalates as P0.
