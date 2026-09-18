# project-template

Template for `ulisseas/*` projects. A repo created from it builds on every
push and pull request, exports every CI and Release run as traces and metrics
to the portfolio's monitoring, and cuts a `vX.Y.Z` release from conventional
commits on `main`. Nothing needs to be configured per repo: the credentials
are org-level secrets and variables inherited by every public repo in the org.

## What you get

| Path | Purpose |
|---|---|
| `.github/workflows/ci.yml` | `CI`: `ci-build` (placeholder, replace with the project's build and test steps) and `commitlint`, which lints the commit message the PR will squash-merge as. Both are required checks on `main`. |
| `.github/workflows/telemetry.yml` | `telemetry`: fires when `CI` or `Release` completes and calls the shared [`ulisseas/.github` ci-telemetry](https://github.com/ulisseas/.github) workflow, which exports the run to Honeycomb and Grafana Cloud Traces and pushes two CI metrics to Grafana Cloud Metrics. |
| `.github/workflows/release.yml` | `Release`: semantic-release on push to `main`. Tags `vX.Y.Z`, publishes a GitHub release with generated notes, and uploads the one-line `deployed-version` artifact the Releases dashboard reads. A comment shows where a deploy job goes. |
| `.github/dependabot.yml` | Weekly grouped bumps of GitHub Actions and the npm tooling. |
| `.github/CODEOWNERS` | Review ownership. |
| `scripts/harden-repo.sh` | Idempotent repo hardening: security features, Actions policy, `protect-main` ruleset, squash-only, SHA-pins every `uses:`. GitHub does not copy settings from a template, so this is step 3 below. |
| `scripts/squash-message.py` | Rebuilds the squash commit message from a PR's title and body for `commitlint`. |
| `commitlint.config.cjs`, `.husky/commit-msg` | Conventional commits, enforced locally (`npm install` installs the hook) and in CI. |
| `package.json` | Only the tooling: semantic-release, commitlint, husky. Add the project's own dependencies and scripts. |
| `.editorconfig`, `.gitignore`, `mise.toml`, `LICENSE` (MIT) | Hygiene. |

Every `uses:` is pinned to a full commit SHA with the tag as a trailing
comment, and the repo's Actions policy rejects anything else.

## Create a project from this template

1. **Create the repo in the org.** On this page, *Use this template* →
   *Create a new repository*, owner `ulisseas`, **public** (org secrets and the
   monitoring dashboards are scoped to public repos; a private project lives
   under the personal account instead, see the portfolio-infra onboarding
   guide). Or from a terminal:

       gh repo create ulisseas/<name> --public --template ulisseas/project-template --clone
       cd <name> && npm install

2. **Make it yours.** Replace the placeholder step in `ci-build` with the real
   build and tests, rename `package.json`, and keep the workflow display names
   `CI` and `Release` (or add the new names to `telemetry.yml`). Commit with a
   conventional subject (`feat: …`, `fix: …`, `docs: …`); the husky hook
   rejects anything else.

3. **Harden it.** Once `main` exists on GitHub:

       scripts/harden-repo.sh

   This turns on Dependabot and secret scanning, makes the `GITHUB_TOKEN`
   read-only, allow-lists the OTel exporter action, requires approval for
   workflows from fork PRs, and creates the `protect-main` ruleset: PR-only,
   required checks `ci-build` and `commitlint`, linear history, squash-merge
   only. `DRY_RUN=1` previews. Re-run it whenever a required check or an
   allowed action changes.

The first push to `main` runs `CI`, then `Release` (a `feat:` or `fix:`
subject cuts `v1.0.0`), and `telemetry` exports both. Within a few minutes the
repo shows up on the dashboards below.

## Working in the repo

- Feature branch → PR → squash-merge. The PR **title** becomes the commit on
  `main` and decides the next version, so it must be a conventional commit
  subject; `commitlint` checks title and body before the merge.
- `main` only moves through PRs with `ci-build` and `commitlint` green. There
  are no bypass actors; the release workflow pushes only tags, which a branch
  ruleset does not cover.
- Merges whose subject warrants no release (`docs:`, `ci:`, `chore:`, …)
  cut nothing and ride along with the next `feat:` or `fix:`.

## Adding a deploy

Add a `deploy` job to `release.yml` with `needs: release` and
`if: needs.release.outputs.tag != ''`, and move the two "deployed version"
steps into it. The `deployed-version` artifact must be uploaded by the job
that actually ships, in the run that ships it, so that a rollback reports the
version it restored rather than the version tagged. That label is what the
Releases dashboard plots per repo; the `version` label (tag pointing exactly
at the run's commit) comes for free.

## Dashboards

Public, read-only, fed by every `ulisseas/*` repo that uses this template:

- [Status](https://grafana.ulisseas.com/public-dashboards/dc3e15c21b8a4b2487cdf1dbab08dd64):
  synthetic uptime, latency and TLS expiry of the deployed sites.
- [CI](https://grafana.ulisseas.com/public-dashboards/9c7fd71e4e3d497f8e3be636275dc4a2):
  workflow durations and success rate per repo, from the exported CI metrics.
- [Releases](https://grafana.ulisseas.com/public-dashboards/6d289ba972de4c94ad4b29ebbd0f924a):
  what version each repo has deployed and when, from the `deployed-version`
  artifact.

The monitoring itself (synthetic checks, alert routing, dashboards, the
Honeycomb dataset and the org secrets) is provisioned by the private
`portfolio-infra` repository. Sites also need a synthetic check there; see its
`docs/ONBOARDING.md`.

## License

MIT, see [LICENSE](LICENSE).
