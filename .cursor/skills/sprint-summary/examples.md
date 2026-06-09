# Sprint Summary — Examples

## Example: Three-layer input

### Layer 1: Jira data (queried via MCP)
Pioneers Sprint 54: 70 issues (55 Done, 4 Code Review, 6 In Progress, 5 To Do)
Crookshanks Sprint 54: 77 issues (23 Done, 19 Code Review, 32 In Progress, 3 To Do)
Tekshift Kanban: 20 issues (15 Done, 1 Code Review, 2 In Progress, 2 To Do)

### Layer 2: Manager weekly update (pasted by user)
Key items extracted: AI agent deployment, Summit demo, OTel migration complete, CVE tracker at 248, release 1.23 on track for June 8, support exception for 1.20.

### Layer 3: Upstream releases (fetched from GitHub)
- tektoncd/pipeline v1.12.0 LTS (in sprint window)
- tektoncd/pipelines-as-code v0.46.0 (May 6)
- tektoncd/operator v0.79.1 (May 7)
- tektoncd/cli v0.45.0 (May 12)

## Example: 2-slide output

### Slide 1

```
Sprint 54 — AI Summary
April 28 – May 12, 2026

Sprint Health
- Completed: 93 issues | Carryover: 64 issues | Completion rate: 58%
- CVE tracker: 248 total, 122 past due, 100 awaiting release

Key Accomplishments
- Deployed "Ambient Code" AI agent — autonomously triages CVE tickets and opened first fix PR
- Bulk CVE remediation: CVE-2026-33211 and CVE-2026-33186 across 45+ component images
- Tekton Pipelines v1.12.0 LTS released upstream; Tekton joins CNCF
- OpenCensus to OpenTelemetry migration complete — all PRs merged
- Summit demo delivered: Pipelines-as-Code + AI integration
- Patch releases shipped: 1.20.5, 1.21.2, 1.15.5

Upstream Releases This Sprint
- Pipelines-as-Code v0.46.0 — distributed tracing, Forgejo support
- Operator v0.79.1 "Scarlet Macaw"
- CLI v0.45.0 — customrun describe, OTel migration
```

### Slide 2

```
Sprint 54 — Risks, Releases & Looking Ahead

Release Status
- 1.23: On Track, GA June 8. Initial build in testing.
- 1.15.5: Delayed — new CVEs
- 1.20: 3-month support exception for Citi group
- RPM deprecation complete, removed from 1.23

Risks & Attention
- CVE backlog growing (203 -> 248); 24 items in Code Review
- 7 TLS webhook PRs awaiting upstream review

Looking Ahead
- Land centralized TLS across 7 components
- 1.24.0 release prep; CPT expanding to Chains and Results
- Agentic workflow: AGENTS.md in Operator, console-plugin next sprint
```
