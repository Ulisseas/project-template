#!/usr/bin/env bash
# One-shot (idempotent) hardening of a public ulisseas/* project repository.
# Run it once after creating a project from ulisseas/project-template (repo
# settings, rulesets and Actions policy are NOT copied by GitHub templates),
# and again whenever a required check or an allowed action changes. Modelled
# on ulisseas/.github/scripts/harden-repo.sh.
#
#   1. Security features: Dependabot alerts + security updates, secret scanning
#      + push protection (free on public repos).
#   2. Actions policy: GITHUB_TOKEN read-only, workflows cannot approve PRs, only
#      GitHub-owned / verified / allow-listed actions, full-SHA pins required,
#      and workflows from fork PRs need manual approval before they run.
#   3. Ruleset on main: PR-only, required checks "ci-build" and "commitlint",
#      linear history, no force-push, no deletion, no bypass actors.
#   4. Repo settings: delete head branches on merge, squash-only, no wiki/projects.
#   5. Pin every `uses:` in .github/workflows to a commit SHA (keeps the tag as
#      a trailing comment so Dependabot can still bump it).
#
# Requirements: gh CLI authenticated as an org owner or repo admin
#   (`gh auth status`). The default branch must already exist on GitHub.
#
# Usage:
#   scripts/harden-repo.sh                 # apply to the repo of the current checkout
#   scripts/harden-repo.sh owner/name      # apply to a specific repo
#   DRY_RUN=1 scripts/harden-repo.sh       # print what would change, touch nothing
#
# Tunables (env):
#   REQUIRED_CHECKS="ci-build commitlint"                      space-separated job names
#   ALLOWED_ACTION_PATTERNS="dash0hq/otel-cicd-action@*"       comma-separated third-party actions

set -euo pipefail

REPO="${1:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
DRY_RUN="${DRY_RUN:-0}"
RULESET_NAME="protect-main"
# Job names in .github/workflows/ci.yml. A required-check context is matched
# by job name alone (no workflow binding), so keep them in sync. commitlint is
# required because the PR title becomes the squash commit on main, which
# semantic-release then versions.
read -r -a REQUIRED_CHECKS <<<"${REQUIRED_CHECKS:-ci-build commitlint}"
# Third-party actions allowed in addition to GitHub-owned and verified-creator
# actions. The shared ci-telemetry reusable workflow lives in ulisseas/.github,
# the same org as this repo, so it needs no pattern; the OTel exporter it runs
# does. Everything is SHA-pinned regardless.
ALLOWED_ACTION_PATTERNS="${ALLOWED_ACTION_PATTERNS:-dash0hq/otel-cicd-action@*}"
WORKFLOW_DIR="$(cd "$(dirname "$0")/.." && pwd)/.github/workflows"

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '   ok    %s\n' "$*"; }
skip() { printf '   dry   %s\n' "$*"; }
note() { printf '   note  %s\n' "$*"; }

FAILED=0

run() {   # run "description" gh args... (always returns 0 so set -e doesn't abort)
  local desc="$1"; shift
  if [[ "$DRY_RUN" == 1 ]]; then skip "$desc"; return 0; fi
  if "$@" >/dev/null; then ok "$desc"; else echo "   FAIL   $desc" >&2; FAILED=$((FAILED + 1)); fi
  return 0
}

# ------------------------------------------------------------------ preflight
say "Target repository: $REPO"
repo_json=$(gh repo view "$REPO" --json visibility,defaultBranchRef)
VISIBILITY=$(jq -r .visibility <<<"$repo_json")
DEFAULT_BRANCH=$(jq -r '.defaultBranchRef.name // ""' <<<"$repo_json")
echo "   visibility=$VISIBILITY default=${DEFAULT_BRANCH:-<none>}"
if [[ -z "$DEFAULT_BRANCH" ]]; then
  echo "   ERROR  repository has no default branch yet; push main first" >&2
  exit 1
fi
if [[ "$VISIBILITY" != "PUBLIC" ]]; then
  note "repo is $VISIBILITY. On the org's Free plan rulesets and secret scanning only work on PUBLIC"
  note "repos; keep private projects under the personal account instead (portfolio-infra ONBOARDING.md)."
fi

# ---------------------------------------------------------------- 1. security
say "Security features"
run "Dependabot vulnerability alerts" \
  gh api -X PUT "repos/$REPO/vulnerability-alerts"
run "Dependabot security updates" \
  gh api -X PUT "repos/$REPO/automated-security-fixes"
run "Secret scanning + push protection" \
  gh api -X PATCH "repos/$REPO" --input - <<'JSON'
{
  "security_and_analysis": {
    "secret_scanning": { "status": "enabled" },
    "secret_scanning_push_protection": { "status": "enabled" }
  }
}
JSON

# ---------------------------------------------------------- 2. actions policy
say "Actions policy"
run "GITHUB_TOKEN default permissions=read, workflows cannot approve PRs" \
  gh api -X PUT "repos/$REPO/actions/permissions/workflow" --input - <<'JSON'
{ "default_workflow_permissions": "read", "can_approve_pull_request_reviews": false }
JSON
run "allow only GitHub-owned + verified + allow-listed actions; require full-SHA pins" \
  gh api -X PUT "repos/$REPO/actions/permissions" --input - <<'JSON'
{ "enabled": true, "allowed_actions": "selected", "sha_pinning_required": true }
JSON
patterns_json=$(tr ',' '\n' <<<"$ALLOWED_ACTION_PATTERNS" | sed '/^$/d' | jq -R . | jq -sc .)
run "allow-list patterns: $ALLOWED_ACTION_PATTERNS" \
  gh api -X PUT "repos/$REPO/actions/permissions/selected-actions" --input - <<JSON
{ "github_owned_allowed": true, "verified_allowed": true, "patterns_allowed": $patterns_json }
JSON
# On a public repo anyone can open a PR from a fork. Their workflow runs must
# be approved by a maintainer before they execute, every time.
run "require approval for workflows from all fork PRs" \
  gh api -X PUT "repos/$REPO/actions/permissions/fork-pr-contributor-approval" --input - <<'JSON'
{ "approval_policy": "all_external_contributors" }
JSON
note "sha_pinning_required=true makes GitHub refuse to run a workflow whose 'uses:' is a tag or branch,"
note "so step 5 below is mandatory before a new action can be used. Adding a third-party action"
note "also requires adding it to ALLOWED_ACTION_PATTERNS and re-running."
note "Fork PRs get no secrets and cannot merge; the approval gate stops them from burning minutes."

# --------------------------------------------------------------- 3. ruleset
say "Ruleset '$RULESET_NAME' on $DEFAULT_BRANCH"
required_checks_json=$(printf '{ "context": "%s" },' "${REQUIRED_CHECKS[@]}")
required_checks_json="${required_checks_json%,}"
ruleset_json=$(cat <<JSON
{
  "name": "$RULESET_NAME",
  "target": "branch",
  "enforcement": "active",
  "conditions": { "ref_name": { "include": ["~DEFAULT_BRANCH"], "exclude": [] } },
  "bypass_actors": [],
  "rules": [
    { "type": "deletion" },
    { "type": "non_fast_forward" },
    { "type": "required_linear_history" },
    {
      "type": "pull_request",
      "parameters": {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": true,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": true,
        "allowed_merge_methods": ["squash"]
      }
    },
    {
      "type": "required_status_checks",
      "parameters": {
        "strict_required_status_checks_policy": true,
        "do_not_enforce_on_create": true,
        "required_status_checks": [ $required_checks_json ]
      }
    }
  ]
}
JSON
)
existing_id=$(gh api "repos/$REPO/rulesets" --jq ".[] | select(.name==\"$RULESET_NAME\") | .id" 2>/dev/null || true)
if [[ -n "$existing_id" ]]; then
  run "update ruleset id=$existing_id" \
    gh api -X PUT "repos/$REPO/rulesets/$existing_id" --input - <<<"$ruleset_json"
else
  run "create ruleset" \
    gh api -X POST "repos/$REPO/rulesets" --input - <<<"$ruleset_json"
fi
note "required_approving_review_count=0: a solo maintainer can't approve their own PR;"
note "the PR + passing '${REQUIRED_CHECKS[*]}' checks are the gate."
note "No bypass actors: release.yml only pushes tags, which a branch ruleset does not cover. A project"
note "that adds @semantic-release/git (commits the bump back to main) needs a DeployKey bypass actor."

# ----------------------------------------------------------- 4. repo settings
say "Repository settings"
run "delete branch on merge, suggest branch updates, squash-only, no wiki/projects" \
  gh api -X PATCH "repos/$REPO" --input - <<'JSON'
{
  "delete_branch_on_merge": true,
  "allow_update_branch": true,
  "allow_auto_merge": false,
  "allow_squash_merge": true,
  "allow_merge_commit": false,
  "allow_rebase_merge": false,
  "squash_merge_commit_title": "PR_TITLE",
  "squash_merge_commit_message": "PR_BODY",
  "has_wiki": false,
  "has_projects": false
}
JSON

# --------------------------------------------------------- 5. pin action SHAs
say "Pin GitHub Actions to commit SHAs in $WORKFLOW_DIR"
if [[ ! -d "$WORKFLOW_DIR" ]]; then
  note "no workflows directory; nothing to pin."
fi
CACHE_FILE=$(mktemp)
changed=0
for wf in "$WORKFLOW_DIR"/*.yml "$WORKFLOW_DIR"/*.yaml; do
  [[ -f "$wf" ]] || continue
  tmp=$(mktemp)
  while IFS= read -r line; do
    # match:  uses: owner/repo@ref   (optionally already "@sha # tag")
    if [[ "$line" =~ ^([[:space:]]*-?[[:space:]]*uses:[[:space:]]*)([A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+)@([A-Za-z0-9_.\/-]+)([[:space:]]*#.*)?$ ]]; then
      prefix="${BASH_REMATCH[1]}"; action="${BASH_REMATCH[2]}"; ref="${BASH_REMATCH[3]}"
      # Skip local actions, already-pinned SHAs, and the org's shared reusable
      # workflow, which callers reference @main on purpose.
      if [[ "$action" == ./* ]] || [[ "$ref" =~ ^[0-9a-f]{40}$ ]] || [[ "$action" == ulisseas/.github/* ]]; then
        printf '%s\n' "$line" >>"$tmp"; continue
      fi
      key="$action@$ref"
      # File-based cache lookup (bash 3.x compatible; no associative arrays)
      sha=$(grep -E "^${key}=" "$CACHE_FILE" 2>/dev/null | tail -1 | cut -d= -f2- || echo "")
      if [[ -z "$sha" ]]; then
        # owner/repo may include a subdirectory (owner/repo/path); API wants owner/repo
        api_repo=$(cut -d/ -f1,2 <<<"$action")
        sha=$(gh api "repos/$api_repo/commits/$ref" --jq .sha 2>/dev/null || true)
      fi
      if [[ -z "${sha:-}" ]]; then
        echo "   warn  could not resolve $key; leaving as-is" >&2
        printf '%s\n' "$line" >>"$tmp"
      else
        echo "${key}=${sha}" >>"$CACHE_FILE"
        printf '%s%s@%s # %s\n' "$prefix" "$action" "$sha" "$ref" >>"$tmp"
        ok "$(basename "$wf"): $key -> ${sha:0:12}"
        changed=1
      fi
    else
      printf '%s\n' "$line" >>"$tmp"
    fi
  done <"$wf"
  if [[ "$DRY_RUN" == 1 ]]; then rm -f "$tmp"; else mv "$tmp" "$wf"; fi
done
rm -f "$CACHE_FILE"
if (( changed )) && [[ "$DRY_RUN" != 1 ]]; then
  note "workflows rewritten; review with 'git diff .github/workflows' and commit on a feature branch."
fi

# ------------------------------------------------------------------ summary
say "Done"
echo "   Verify:"
echo "     gh api repos/$REPO/rulesets --jq '.[].name'"
echo "     gh api repos/$REPO/actions/permissions/fork-pr-contributor-approval"
echo "     gh api repos/$REPO/actions/permissions/selected-actions"
echo "     gh repo view $REPO --web   (Settings > Rules, Code security, Actions)"

if (( FAILED > 0 )); then
  echo "$FAILED step(s) FAILED - review output above" >&2
  exit 1
fi
