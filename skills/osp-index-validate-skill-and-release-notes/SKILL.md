---
name: osp-index-validate
description: >-
  Use when validating OpenShift Pipelines OLM catalog index images, comparing
  index builds, generating changelogs between index versions, or verifying
  operator bundles. Triggers: "validate this index", "compare indexes",
  "generate changelog", "verify bundle", nightly TS, release validation,
  index image SHA, quay.io/openshift-pipeline/pipelines-index.
---

# OSP Index Validation & Changelog Generation

Validates OpenShift Pipelines OLM catalog index images by extracting upstream commit SHAs from component container images, comparing them against upstream GitHub repos, and generating structured changelogs.

## Quick Reference

```
# Extract component info from an index image
CONTAINERS_OVERRIDE_ARCH=amd64 python3 osp_index_info/main.py full-info '<index_image_ref>' 2>/dev/null | python3 -m json.tool

# Compare two indexes via the script
CONTAINERS_OVERRIDE_ARCH=amd64 python3 osp_index_info/main.py compare '<old_image>' '<new_image>' show-all-commits -o json

# GitHub compare API
curl -s 'https://api.github.com/repos/{owner}/{repo}/compare/{base_sha}...{head_sha}'
# Returns: status (ahead|behind|identical|diverged), ahead_by, behind_by, commits[]
```

## Prerequisites

- `podman` running (`podman machine start` if needed)
- On Apple Silicon: `CONTAINERS_OVERRIDE_ARCH=amd64` is required — index images are amd64-only
- `python3` (not `python`)
- `jq` for JSON processing
- GitHub API access (unauthenticated is fine for public repos, rate limit ~60/hr)

## Image-to-Repo Mapping

The script uses `IMAGE_REPO_TO_GIT_REPO` in `osp_index_info/main.py` to map container image names to upstream GitHub repos. Key mappings:

```
pipelines-controller-rhel9          → tektoncd/pipeline
pipelines-pipelines-as-code-*-rhel9 → tektoncd/pipelines-as-code   (NOT openshift-pipelines/)
pipelines-chains-controller-rhel9   → tektoncd/chains
pipelines-cli-tkn-rhel9             → tektoncd/cli
pipelines-rhel9-operator            → tektoncd/operator
pipelines-triggers-*-rhel9          → tektoncd/triggers
pipelines-results-*-rhel9           → tektoncd/results
pipelines-hub-*-rhel9               → tektoncd/hub
pipelines-pruner-*-rhel9            → tektoncd/pruner
pipelines-manual-approval-gate-*    → openshift-pipelines/manual-approval-gate
pipelines-cache-rhel9               → openshift-pipelines/tekton-caches
```

Third-party images (buildah, skopeo, postgresql, ubi-minimal, openjdk) come from `registry.redhat.io` and have no upstream commit info — this is expected.

## Workflow

### Step 1: Extract Component Info

```bash
CONTAINERS_OVERRIDE_ARCH=amd64 python3 osp_index_info/main.py full-info \
  'quay.io/openshift-pipeline/pipelines-index-4.18@sha256:<digest>' \
  2>/dev/null | python3 -m json.tool > /tmp/index_info.json
```

Output is JSON with `version` and `images` dict. Each image entry has:
- `image`: full image reference
- `upstream_commit`: SHA from the upstream GitHub repo
- `downstream_commit`: SHA from the downstream (Red Hat) repo
- `git_link`: link to upstream commit

Redirect stderr (`2>/dev/null`) to suppress auth errors from registry.redhat.io images.

### Step 2: Compare Upstream Commits

For each changed component, compare old vs new upstream SHA using the GitHub API:

```bash
curl -s 'https://api.github.com/repos/{owner}/{repo}/compare/{old_sha}...{new_sha}'
```

Key fields in response:
- `status`: `ahead` (new is newer), `behind` (regression!), `identical`, `diverged` (different branches)
- `ahead_by` / `behind_by`: commit counts
- `commits[]`: array of commit objects with `sha`, `commit.message`, `commit.committer.date`

**Diverged means different branches** — e.g., moving from `release-v1.12.x` to `main`. This is important context, not necessarily a problem.

### Step 3: Validate Against Tags

Check component versions against upstream release tags:

```bash
curl -s 'https://api.github.com/repos/{owner}/{repo}/git/refs/tags' | \
  python3 -c "import json,sys; [print(f\"{t['ref'].replace('refs/tags/','')}: {t['object']['sha'][:8]}\") for t in json.load(sys.stdin)]"
```

**Gotcha — annotated tags**: Some tags (CLI, Triggers) are annotated tag objects, not direct commits. If `type` is `tag` instead of `commit`, dereference:
```bash
curl -s 'https://api.github.com/repos/{owner}/{repo}/git/tags/{tag_object_sha}' | jq -r '.object.sha'
```

### Step 4: Generate Changelog

For each changed component:

1. Get the commit list from the compare API (`?per_page=100`, paginate if needed)
2. Filter out pure dependency bumps — focus on:
   - **Security fixes** (CVE-*, bump golang.org/x/*, bump Go version)
   - **Bug fixes** (fix:, Fix:)
   - **New features** (feat:, Add, Implement)
   - **Breaking changes** (Remove, breaking, deprecate)
   - **Performance** (perf:, optimize)
3. Group by component with compare URL links
4. Note version changes (e.g., v0.46.0 → v0.47.0)

### Step 5: Verify Operator Bundles

Bundles are different from index images — they contain the CSV (ClusterServiceVersion) with actual image references:

```bash
# Pull and inspect the bundle
podman pull --platform linux/amd64 '<bundle_image_ref>'
podman inspect '<bundle_image_ref>' | python3 -c "
import json,sys
labels = json.load(sys.stdin)[0]['Config']['Labels']
print(f\"upstream-vcs-ref: {labels.get('upstream-vcs-ref')}\")
print(f\"version: {labels.get('version')}\")
"

# Extract individual component images from the CSV
CONTAINER=$(podman create '<bundle_image_ref>')
podman cp "$CONTAINER:/manifests/" /tmp/bundle_manifests/
grep -E 'image:.*quay.io/openshift-pipeline' /tmp/bundle_manifests/*.clusterserviceversion.yaml
```

Then inspect each component image to get its `upstream-vcs-ref` label and compare against the index.

## Output Formatting

### For GitHub / Markdown consumers
Use standard markdown tables and `### Heading` sections.

### For Slack
Slack does NOT render markdown tables. Use this format instead:

- Headers: `*bold text*` (Slack bold)
- Tables: wrap in triple-backtick code blocks with aligned columns
- Separators: `━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`
- Bullets: `•` character
- Commit lists: code blocks with `sha  message` format

```
*Component Summary*

\`\`\`
Component   Prod (806)                  Index 830                     Bundle (new)
─────────   ──────────                  ─────────                     ────────────
Pipeline    8d33f2ae (release-v1.12.x)  b150ab2d (release-v1.12.x)    31e72265 (v1.13.0)
\`\`\`
```

## Common Gotchas

| Issue | Fix |
|-------|-----|
| `no image found for architecture arm64` | Use `CONTAINERS_OVERRIDE_ARCH=amd64` and `podman pull --platform linux/amd64` |
| `python` not found | Use `python3` on macOS |
| registry.redhat.io auth errors | Redirect stderr: `2>/dev/null`. Third-party images won't have upstream info |
| zsh glob error on `?` in URLs | Quote URLs: `curl -s 'https://...?per_page=100'` |
| GitHub compare returns 0 commits | Use full 40-char SHAs, not short SHAs |
| Compare status `diverged` | Components moved between branches (e.g., release → main). Check both `ahead_by` and `behind_by` |
| Tag SHA doesn't match commit | Annotated tag — dereference via `git/tags/{sha}` endpoint |
| PAC repo returns nulls | Use `tektoncd/pipelines-as-code`, NOT `openshift-pipelines/pipelines-as-code` |
| podman `Cannot connect` | Run `podman machine start` |
| `/tmp` files gone | Podman machine restart clears `/tmp`. Re-run extraction commands |

## Changelog Template

```
*Component Changelog: {old_version} → {new_version}*
Built: {date}

*Component Summary*

\`\`\`
Component   Old                         New                           Change
─────────   ───                         ───                           ──────
Pipeline    {sha} ({version})           {sha} ({version})             +N commits
PAC         {sha} ({version})           {sha} ({version})             +N commits
\`\`\`

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

*Pipeline* ({old_version} → {new_version}, +N commits)
Compare: https://github.com/tektoncd/pipeline/compare/{old_sha}...{new_sha}

\`\`\`
{sha}  {commit message}
{sha}  {commit message}
\`\`\`

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

*Key Observations*

• {observation 1}
• {observation 2}
```
