#!/usr/bin/env bash
# Phase 7 – protect main and invite the developers (idempotent).
# - main: PR required, 1 code-owner approval, stale approvals dismissed, CI job "validate" must pass
#   (only accepted from GitHub Actions), branch up to date, linear history, no force-push / deletion.
# - squash-merge only, head branches deleted after merge.
# - developers (GH_DEVELOPERS) get push access, so they can open PRs from branches in this repo.
# Caveat: on a personal repo every collaborator with push access may press "merge"; protection only
# guarantees that a merge needs an admin approval and a green "validate" check.
set -euo pipefail
cd "$(dirname "$0")/.."
source ./00-env.sh
R="$GH_OWNER/$GH_REPO"
ENFORCE_ADMINS=${ENFORCE_ADMINS:-false}
GITHUB_ACTIONS_APP_ID=15368

gh api -X PATCH "repos/$R" --silent \
  -F allow_squash_merge=true -F allow_merge_commit=false -F allow_rebase_merge=false \
  -F delete_branch_on_merge=true -F allow_auto_merge=false \
  -f squash_merge_commit_title=PR_TITLE -f squash_merge_commit_message=PR_BODY
echo "repo settings: squash-merge only, delete branch on merge"

gh api -X PUT "repos/$R/branches/main/protection" --silent --input - <<EOF
{
  "required_status_checks": { "strict": true, "checks": [ { "context": "validate", "app_id": $GITHUB_ACTIONS_APP_ID } ] },
  "enforce_admins": $ENFORCE_ADMINS,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "require_code_owner_reviews": true,
    "dismiss_stale_reviews": true,
    "require_last_push_approval": true
  },
  "restrictions": null,
  "required_linear_history": true,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": true
}
EOF
echo "branch protection on main (enforce_admins=$ENFORCE_ADMINS)"

for dev in ${GH_DEVELOPERS//,/ }; do
  if gh api "repos/$R/collaborators/$dev" --silent 2>/dev/null; then
    echo "$dev: already a collaborator"
  else
    gh api -X PUT "repos/$R/collaborators/$dev" -f permission=push --silent
    echo "$dev: invited with push access (must accept: https://github.com/$R/invitations)"
  fi
done
