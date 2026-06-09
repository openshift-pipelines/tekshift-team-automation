---
name: sprint-summary
description: >-
  Generate OpenShift Pipelines sprint review AI Summary from three data layers:
  Jira sprint boards, manager weekly update emails, and upstream GitHub releases.
  Produces a combined 2-slide summary for Google Slides and a Cursor Canvas.
  Use when the user mentions sprint review, sprint summary, sprint slide deck,
  Pipelines sprint, or summarized sprint metrics.
disable-model-invocation: true
---

# Sprint Review Summary (OpenShift Pipelines)

Produces a **combined Pipelines-wide AI Summary** (2 slides, placed before Q&A) by pulling from three data layers:

1. **Jira** — sprint board issues, metrics, completion rates
2. **Email** — manager's weekly update (project updates, release health, shoutouts)
3. **Upstream releases** — GitHub releases from Tekton/OpenShift Pipelines repos

## Permissions — STRICT

- **Jira**: READ ONLY. No creates, updates, deletes, transitions, or comments without explicit user approval.
- **GitHub**: READ ONLY. Only fetch release pages.
- **Email**: User provides the content (paste or forward). Agent never accesses email directly.

## Teams

| Team | Sprint naming pattern | Type |
|------|----------------------|------|
| **Pioneers** | "Pipelines Sprint Pioneers {N}" | Scrum |
| **Crookshanks** | "Pipelines Sprint Crookshank {N}" | Scrum |
| **Tekshift** | "TekShift Ranked Board" | Kanban |

All teams share **SRVKP** project, **board 7963**. Exclude board 4598 (Release) and board 4603 (Perf&Scale).

## Jira config

<!-- Replace YOUR_CLOUD_ID with your Atlassian cloud ID (find via getAccessibleAtlassianResources) -->
- Cloud ID: `YOUR_CLOUD_ID`
- MCP server: `plugin-atlassian-atlassian`
- Tool: `searchJiraIssuesUsingJql`
- Sprint field: `customfield_10020`
- Story points: not reliably returned (try `customfield_12310243`; fall back to issue counts)

## Upstream repos to check for releases

| Repo | Check? |
|------|--------|
| tektoncd/pipeline | Always |
| tektoncd/pipelines-as-code | Always |
| tektoncd/operator | Always |
| tektoncd/cli | Always |
| tektoncd/chains | Always |
| tektoncd/triggers | Always |
| tektoncd/results | Always |
| tektoncd/pruner | Always |
| tektoncd/hub | Always |
| openshift-pipelines/manual-approval-gate | Always |
| openshift-pipelines/tekton-caches | Always |

---

## Workflow

### 1. Collect data from all three layers

#### Layer 1: Jira

Query these JQL statements (read-only, `maxResults: 100`, paginate if needed):

```
# Pioneers
project = SRVKP AND sprint = "Pipelines Sprint Pioneers {N}" ORDER BY status DESC

# Crookshanks
project = SRVKP AND sprint = "Pipelines Sprint Crookshank {N}" ORDER BY status DESC

# Tekshift (Kanban — filter by date)
project = SRVKP AND sprint = "TekShift Ranked Board" AND updated >= "{sprint_start}" ORDER BY status DESC
```

Fields: `["summary", "status", "issuetype", "assignee", "labels", "components", "fixVersions", "resolution", "customfield_12310243", "customfield_10020"]`

If the user provides a sprint retrospective URL (e.g. `boards/7963/reports/sprint-retrospective?sprint=XXXXX`), extract the sprint ID and query by ID: `sprint = {id}`.

For each issue, extract: key, summary, status (+ category), issue type, story points, components, fix versions.

#### Layer 2: Weekly update email

Ask the user to paste the manager's weekly update email(s) covering the sprint window. Extract:

- **Focus area updates** (Visibility, Quality, Efficiency)
- **Project updates** (demos, AI/agentic work, notable achievements)
- **Release health** (GA dates, delays, CVE tracker counts, support exceptions)
- **Migration status** (OTel, TLS, RPM deprecation, etc.)
- **Documentation status**
- **Performance updates**
- **Shoutouts and milestones**

These fill the narrative gaps that Jira tickets alone miss.

#### Layer 3: Upstream GitHub releases

For each repo in the table above, check `https://github.com/{repo}/releases` for releases dated within the sprint window. Use `WebFetch` or `WebSearch` to get release dates and highlights.

Capture: repo name, version, release date, key features/changes (1-2 bullets).

### 2. Merge and deduplicate

Combine all three layers into a unified view:

- **Jira** provides: issue counts, completion rates, carryover, status breakdowns
- **Email** provides: strategic context, release health, demos, people milestones, risk signals (e.g. CVE tracker growth)
- **Upstream** provides: community releases shipped during the sprint

Cross-reference to avoid duplication (e.g. if a Jira ticket and email both mention the same release, merge into one bullet).

### 3. Generate the 2-slide AI Summary

**Slide 1: Sprint [N] — AI Summary**

```
Sprint [N] — AI Summary
[Date Range]

## Sprint Health
- Completed: X issues | Carryover: X issues | Completion rate: XX%
- CVE tracker: X total, X past due, X awaiting release

## Key Accomplishments
- [4-6 bullets: top achievements from Jira + email + upstream releases]
- [Include: major features, AI/agentic work, demos, upstream releases, migrations completed]

## Upstream Releases
- [List repos with versions released during the sprint, 1 line each]
```

**Slide 2: Sprint [N] — Risks, Releases & Looking Ahead**

```
## Release Status
- [Per-release line: version, status, GA date if known]

## Risks & Attention
- [CVE backlog trends, Code Review bottlenecks, delays]
- [2-4 bullets max]

## Looking Ahead
- [Key carryover, upcoming priorities, next sprint focus]
- [3-4 bullets max]
```

**Rules:**
- Combined Pipelines-wide view — do NOT split by sub-team
- Keep each slide to ~6-8 bullets total (scannable, not a wall of text)
- No emoji in the output
- Blend Jira metrics with email narrative and upstream releases naturally

### 4. Generate Canvas

Read `~/.cursor/skills-cursor/canvas/SKILL.md` for layout rules. Create or update `canvases/sprint-summary.canvas.tsx`.

Canvas layout:
- `H1` + date range
- `Grid` of `Stat` (completed, carryover, completion rate, CVE count)
- `Divider` + `H2` Key Accomplishments (Text bullets)
- `Divider` + `H2` Upstream Releases (compact Text list)
- `Divider` + `H2` Release Status (Text)
- `Divider` + `H2` Risks (`Callout` with `tone="warning"`)
- `Divider` + `H2` Looking Ahead (Text)

Constraints: import only from `cursor/canvas`, no fetch, no emoji, colors via `useHostTheme()`.

### 5. Review and iterate

Ask the user if the summary needs adjustments before pasting into Google Slides.

## Additional resources

- Examples: [examples.md](examples.md)
