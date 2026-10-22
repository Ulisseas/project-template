#!/usr/bin/env bash
# One-shot (idempotent) hardening of a public ulisseas/* project repository.
# Run it once after creating a project from ulisseas/project-template (repo
# settings, rulesets and Actions policy are NOT copied by GitHub templates),
# and again whenever a required check or an allowed action changes. Modelled
# on ulisseas/.github/scripts/harden-repo.sh.
#
# Preflight: before changing anything, read the workflows on the default branch
# on GitHub and refuse to apply if the settings below would break them:
#   - a required status check has not run there (a wrong check name blocks
#     every merge, permanently and silently);
#   - an action is not on the allow-list (its workflow would stop running);
#   - an action is not pinned to a full commit SHA (with SHA pinning required,
#     it would fail).
#   A dry run reports the same problems and exits 1, so it doubles as an audit.
#   Other rulesets that stack with the managed ones are listed as a note.
#
#   1. Pin every `uses:` in .github/workflows to a commit SHA (keeps the tag as
#      a trailing comment so Dependabot can still bump it). This only rewrites
#      the local checkout, so it runs even when the preflight refuses: merge
#      the pins, then re-run.
#   2. Security features: Dependabot alerts + security updates, secret scanning
#      + push protection (free on public repos), immutable releases.
#   3. Actions policy: GITHUB_TOKEN read-only, workflows cannot approve PRs, only
#      GitHub-owned / verified / allow-listed actions, full-SHA pins required,
#      and workflows from fork PRs need manual approval before they run.
#   4. Rulesets, no bypass actors on either:
#      "protect-main" on main: PR-only, required checks "ci-build" and
#      "commitlint", linear history, no force-push, no deletion.
#      "protect-release-tags" on v* tags: no deletion, force-push or moving.
#   5. Repo settings: delete head branches on merge, squash-only, no
#      wiki/projects/discussions.
#   6. Labels listed in .github/dependabot.yml. Dependabot ignores a label that
#      does not exist (and a custom labels: list replaces its default
#      "dependencies" label), so without these its PRs arrive unlabelled.
#
# Requirements: gh CLI authenticated as an org owner or repo admin
#   (`gh auth status`), and jq. The default branch must already exist on GitHub.
#
# Usage:
#   scripts/harden-repo.sh                 # apply to the repo of the current checkout
#   scripts/harden-repo.sh owner/name      # apply to a specific repo
#   DRY_RUN=1 scripts/harden-repo.sh       # audit and print what would change, touch nothing
#   scripts/harden-repo.sh --help          # print this header
#
# Tunables (env):
#   REQUIRED_CHECKS="ci-build commitlint"          space-separated job names
#   ALLOWED_ACTIONS="dash0hq/otel-cicd-action@*"   space-separated third-party action patterns
#   RELEASE_TAG_PATTERN="refs/tags/v*"             tags the release ruleset protects

set -euo pipefail

REPO=""
for arg in "$@"; do
  case "$arg" in
    # Print the header comment above, whatever its length.
    -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
    -*) echo "unknown option: $arg (see --help)" >&2; exit 2 ;;
    *) REPO="$arg" ;;
  esac
done

command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
REPO="${REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
if [[ ! "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "not an OWNER/REPO: $REPO" >&2
  exit 2
fi
OWNER="${REPO%%/*}"
DRY_RUN="${DRY_RUN:-0}"
RULESET_NAME="protect-main"
TAG_RULESET_NAME="protect-release-tags"
# semantic-release (.github/workflows/release.yml) tags every release vX.Y.Z.
RELEASE_TAG_PATTERN="${RELEASE_TAG_PATTERN:-refs/tags/v*}"
# Job names in .github/workflows/ci.yml. A required-check context is matched
# by job name alone (no workflow binding), so keep them in sync. commitlint is
# required because the PR title becomes the squash commit on main, which
# semantic-release then versions.
read -r -a REQUIRED_CHECKS <<<"${REQUIRED_CHECKS:-ci-build commitlint}"
# Third-party actions allowed in addition to GitHub-owned and verified-creator
# actions. The shared ci-telemetry reusable workflow lives in ulisseas/.github,
# the same org as this repo, so it needs no pattern; the OTel exporter it runs
# does. Everything is SHA-pinned regardless. The preflight can't tell which
# creators are verified, so it wants every third-party action listed here.
read -r -a ALLOWED_ACTIONS <<<"${ALLOWED_ACTIONS:-dash0hq/otel-cicd-action@*}"
WORKFLOW_DIR="$(cd "$(dirname "$0")/.." && pwd)/.github/workflows"
# name|colour|description, one per line. Keep in sync with the labels: entries
# in .github/dependabot.yml.
DEPENDABOT_LABELS="${DEPENDABOT_LABELS:-$(cat <<'LABELS'
dependencies|0366d6|Dependency update opened by Dependabot
npm|cb3837|npm package update
github-actions|2088ff|GitHub Actions update
LABELS
)}"

say()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
ok()   { printf '   ok    %s\n' "$*"; }
skip() { printf '   dry   %s\n' "$*"; }
note() { printf '   note  %s\n' "$*"; }
lower() { tr '[:upper:]' '[:lower:]' <<<"$1"; }   # bash 3.2 has no ${var,,}

FAILED=0
PROBLEMS=()

run() {   # run "description" gh args... (always returns 0 so set -e doesn't abort)
  local desc="$1"; shift
  if [[ "$DRY_RUN" == 1 ]]; then skip "$desc"; return 0; fi
  if "$@" >/dev/null; then ok "$desc"; else echo "   FAIL   $desc" >&2; FAILED=$((FAILED + 1)); fi
  return 0
}

problem() {   # problem "message": record a preflight problem once
  local p
  for p in ${PROBLEMS[@]+"${PROBLEMS[@]}"}; do [[ "$p" == "$1" ]] && return 0; done
  PROBLEMS+=("$1")
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
# Every page, flattened. Includes org rulesets that apply here (source_type
# "Organization"), which can't be edited through the repo.
RULESETS_JSON=$(gh api --paginate "repos/$REPO/rulesets" | jq -sc 'add // []')

say "Preflight: workflows on $DEFAULT_BRANCH"
ran=$(gh api --paginate "repos/$REPO/commits/$DEFAULT_BRANCH/check-runs?per_page=100" \
  | jq -rs '[.[].check_runs[].name] | unique | .[]')
for check in "${REQUIRED_CHECKS[@]}"; do
  if grep -qxF -- "$check" <<<"$ran"; then
    ok "required check '$check' ran on $DEFAULT_BRANCH"
  else
    problem "required check '$check' has not run on $DEFAULT_BRANCH; checks seen: $(paste -sd, - <<<"$ran")"
  fi
done
workflows=$(gh api "repos/$REPO/contents/.github/workflows?ref=$DEFAULT_BRANCH" \
  --jq '.[] | select(.name | test("\\.ya?ml$")) | .path' 2>/dev/null || true)
while IFS= read -r wf; do
  [[ -n "$wf" ]] || continue
  while IFS= read -r use; do
    [[ "$use" == ./* || "$use" == docker://* ]] && continue
    action="${use%%@*}"; ref="${use#*@}"
    # Owner and repo names are case-insensitive on GitHub, and gh reports the
    # org as "Ulisseas" while workflows say "ulisseas", so compare in lowercase.
    use_lc=$(lower "$use"); owner="${use_lc%%/*}"
    # GitHub-owned actions and this owner's own (e.g. ulisseas/.github's
    # reusable workflow) are allowed without a pattern.
    if [[ "$owner" != actions && "$owner" != github && "$owner" != "$(lower "$OWNER")" ]]; then
      allowed=0
      for pattern in ${ALLOWED_ACTIONS[@]+"${ALLOWED_ACTIONS[@]}"}; do
        # shellcheck disable=SC2053  # the pattern is a glob on purpose
        [[ "$use_lc" == $(lower "$pattern") ]] && allowed=1
      done
      (( allowed )) || problem "$wf uses $use, which is not in ALLOWED_ACTIONS"
    fi
    [[ "$ref" =~ ^[0-9a-f]{40}$ ]] || problem "$wf uses $use, which is not pinned to a full commit SHA"
  done < <(gh api -H "Accept: application/vnd.github.raw" "repos/$REPO/contents/$wf?ref=$DEFAULT_BRANCH" \
    | sed -nE 's/^[[:space:]-]*uses:[[:space:]]*["'\'']?([^"'\''[:space:]#]+).*/\1/p')
done <<<"$workflows"
ok "checked actions in: $(paste -sd' ' - <<<"$workflows")"
others=$(jq -r --arg b "$RULESET_NAME" --arg t "$TAG_RULESET_NAME" '.[]
  | select((.source_type == "Repository" and (.name == $b or .name == $t)) | not)
  | "\(.name) (\(.target), \(.enforcement), from \(.source_type) \(.source))"' <<<"$RULESETS_JSON")
if [[ -n "$others" ]]; then
  note "other rulesets also apply and stack with the managed ones (the strictest rule wins):"
  while IFS= read -r line; do note "  $line"; done <<<"$others"
fi
for p in ${PROBLEMS[@]+"${PROBLEMS[@]}"}; do echo "   PROBLEM  $p" >&2; done

# --------------------------------------------------------- 1. pin action SHAs
# Local files only, so it runs before the preflight gate: an unpinned action is
# fixed by merging this step's rewrite.
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
      # Skip local actions and already-pinned SHAs. The ci-telemetry reusable
      # workflow is pinned like any action (to a ulisseas/.github release tag).
      if [[ "$action" == ./* ]] || [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
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

if (( ${#PROBLEMS[@]} )) && [[ "$DRY_RUN" != 1 ]]; then
  echo >&2
  echo "Refusing to apply: ${#PROBLEMS[@]} preflight problem(s) above would block merges or" >&2
  echo "workflow runs. Fix them on $DEFAULT_BRANCH (merge any pins from step 1), then re-run." >&2
  exit 1
fi

# ---------------------------------------------------------------- 2. security
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
# A published release's tag and assets can't change. release.yml publishes
# notes only (deployed-version is a workflow artifact, not a release asset).
# A project that adds release assets must upload them before publishing:
# @semantic-release/github does, via a draft.
run "Immutable releases" \
  gh api -X PUT "repos/$REPO/immutable-releases"

# ---------------------------------------------------------- 3. actions policy
say "Actions policy"
run "GITHUB_TOKEN default permissions=read, workflows cannot approve PRs" \
  gh api -X PUT "repos/$REPO/actions/permissions/workflow" --input - <<'JSON'
{ "default_workflow_permissions": "read", "can_approve_pull_request_reviews": false }
JSON
run "allow only GitHub-owned + verified + allow-listed actions; require full-SHA pins" \
  gh api -X PUT "repos/$REPO/actions/permissions" --input - <<'JSON'
{ "enabled": true, "allowed_actions": "selected", "sha_pinning_required": true }
JSON
selected_json=$(printf '%s\n' ${ALLOWED_ACTIONS[@]+"${ALLOWED_ACTIONS[@]}"} | sed '/^$/d' | jq -R . \
  | jq -sc '{ github_owned_allowed: true, verified_allowed: true, patterns_allowed: . }')
run "allow-list patterns: ${ALLOWED_ACTIONS[*]:-<none>}" \
  gh api -X PUT "repos/$REPO/actions/permissions/selected-actions" --input - <<<"$selected_json"
# On a public repo anyone can open a PR from a fork. Their workflow runs must
# be approved by a maintainer before they execute, every time.
run "require approval for workflows from all fork PRs" \
  gh api -X PUT "repos/$REPO/actions/permissions/fork-pr-contributor-approval" --input - <<'JSON'
{ "approval_policy": "all_external_contributors" }
JSON
note "sha_pinning_required=true makes GitHub refuse to run a workflow whose 'uses:' is a tag or branch,"
note "so step 1 above is mandatory before a new action can be used. Adding a third-party action"
note "also requires adding it to ALLOWED_ACTIONS and re-running."
note "Fork PRs get no secrets and cannot merge; the approval gate stops them from burning minutes."

# --------------------------------------------------------------- 4. rulesets
upsert_ruleset() {   # upsert_ruleset NAME JSON: update this repo's ruleset NAME in place, or create it
  local name="$1" body="$2" id
  id=$(jq -r --arg n "$name" \
    '[.[] | select(.source_type == "Repository" and .name == $n) | .id] | first // empty' <<<"$RULESETS_JSON")
  if [[ -n "$id" ]]; then
    run "update ruleset '$name' id=$id" \
      gh api -X PUT "repos/$REPO/rulesets/$id" --input - <<<"$body"
  else
    run "create ruleset '$name'" \
      gh api -X POST "repos/$REPO/rulesets" --input - <<<"$body"
  fi
}

say "Ruleset '$RULESET_NAME' on $DEFAULT_BRANCH"
required_checks_json=$(printf '%s\n' "${REQUIRED_CHECKS[@]}" | jq -R '{ context: . }' | jq -sc .)
upsert_ruleset "$RULESET_NAME" "$(jq -n --arg name "$RULESET_NAME" --argjson checks "$required_checks_json" '{
  name: $name,
  target: "branch",
  enforcement: "active",
  conditions: { ref_name: { include: ["~DEFAULT_BRANCH"], exclude: [] } },
  bypass_actors: [],
  rules: [
    { type: "deletion" },
    { type: "non_fast_forward" },
    { type: "required_linear_history" },
    {
      type: "pull_request",
      parameters: {
        required_approving_review_count: 0,
        dismiss_stale_reviews_on_push: true,
        require_code_owner_review: false,
        require_last_push_approval: false,
        required_review_thread_resolution: true,
        allowed_merge_methods: ["squash"]
      }
    },
    {
      type: "required_status_checks",
      parameters: {
        strict_required_status_checks_policy: true,
        do_not_enforce_on_create: true,
        required_status_checks: $checks
      }
    }
  ]
}')"
note "required_approving_review_count=0: a solo maintainer can't approve their own PR;"
note "the PR + passing '${REQUIRED_CHECKS[*]}' checks are the gate."
note "No bypass actors: release.yml only pushes tags, which a branch ruleset does not cover. A project"
note "that adds @semantic-release/git (commits the bump back to main) needs a DeployKey bypass actor."

say "Ruleset '$TAG_RULESET_NAME' on $RELEASE_TAG_PATTERN"
upsert_ruleset "$TAG_RULESET_NAME" "$(jq -n --arg name "$TAG_RULESET_NAME" --arg pattern "$RELEASE_TAG_PATTERN" '{
  name: $name,
  target: "tag",
  enforcement: "active",
  conditions: { ref_name: { include: [$pattern], exclude: [] } },
  bypass_actors: [],
  rules: [{ type: "deletion" }, { type: "non_fast_forward" }, { type: "update" }]
}')"
note "Creating tags stays allowed, so the Release workflow can still push a new vX.Y.Z;"
note "nothing can delete, force-push or move one once it exists."

# ----------------------------------------------------------- 5. repo settings
say "Repository settings"
run "delete branch on merge, suggest branch updates, squash-only, no wiki/projects/discussions" \
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
  "has_projects": false,
  "has_discussions": false
}
JSON

# ----------------------------------------------------------------- 6. labels
say "Labels referenced by .github/dependabot.yml"
# --force updates colour and description when the label already exists, so
# the step is idempotent.
while IFS='|' read -r name color desc; do
  [[ -n "$name" ]] || continue
  run "label '$name'" \
    gh label create "$name" --repo "$REPO" --color "$color" --description "$desc" --force
done <<<"$DEPENDABOT_LABELS"

# ------------------------------------------------------------------ summary
say "Done"
echo "   Verify:"
echo "     gh api repos/$REPO/rulesets --jq '.[].name'"
echo "     gh label list --repo $REPO"
echo "     gh api repos/$REPO/immutable-releases"
echo "     gh api repos/$REPO/actions/permissions/fork-pr-contributor-approval"
echo "     gh api repos/$REPO/actions/permissions/selected-actions"
echo "     gh repo view $REPO --web   (Settings > Rules, Code security, Actions)"

status=0
if (( FAILED > 0 )); then
  echo "$FAILED step(s) FAILED - review output above" >&2
  status=1
fi
if (( ${#PROBLEMS[@]} )); then
  echo "Dry run found ${#PROBLEMS[@]} preflight problem(s) above; applying will refuse until they're fixed." >&2
  status=1
fi
exit "$status"
