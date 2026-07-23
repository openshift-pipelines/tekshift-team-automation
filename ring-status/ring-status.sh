#!/bin/bash
# ring-status.sh — Post-upgrade verification and health checks for
# pipeline-service production clusters, organized by ring deployment groups.
#
# Reads cluster membership from ring-mappings.yaml and automates the health
# checks that were previously done manually via individual oc commands.
#
# Requires: oc (OpenShift CLI), yq v4+ (https://github.com/mikefarah/yq)
#           jq (only for --json output)

set -euo pipefail

VERSION="0.1.0"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RINGS_FILE="${SCRIPT_DIR}/ring-mappings.yaml"
OC_TIMEOUT=10  # seconds for oc commands before timing out

# ── Colors ───────────────────────────────────────────────────────────────────
# $'...' ensures \033 is stored as the actual ESC byte (0x1B) so color codes
# render correctly both in printf format strings and %s/%b arguments.
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
RESET=$'\033[0m'

# Disable colors when stdout is not a terminal
if [[ ! -t 1 ]]; then
  RED='' GREEN='' YELLOW='' CYAN='' BOLD='' DIM='' RESET=''
fi

# ── Defaults ─────────────────────────────────────────────────────────────────
ARG_RING=""
ARG_CLUSTER=""
ARG_CONTEXT=""
ARG_SUMMARY=false
ARG_VERIFY=false
ARG_REPO_PATH=""
ARG_JSON=false
ARG_WATCH=false
ARG_WAIT=false
ARG_INTERVAL=5      # seconds between --watch / --wait iterations
ARG_TIMEOUT=0       # --wait only: 0 = no timeout, else max seconds to wait
ARG_DIAG_DIR=""     # custom directory for diagnostic logs
ARG_PR_URL=""       # --pr-overwatch: GitHub PR URL to watch until merge

# ── Diagnostic Log State ──────────────────────────────────────────────────
DIAG_LOG=""                                     # path to current session log
DIAG_LOG_DIR="${TMPDIR:-/tmp}/ring-status-diag" # default log directory
DIAG_HAS_ENTRIES=false                          # true once any diag is written

# Per-target context used by run_oc during multi-cluster iteration.
# Set before each cluster's checks; takes precedence over ARG_CONTEXT.
CURRENT_TARGET_CTX=""

# ── Usage ────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Post-upgrade verification and health checks for pipeline-service production
clusters. Reads cluster-to-ring assignments from ring-mappings.yaml and runs
a standard set of health checks against each target cluster.

Options:
  --ring <N|all>        Check all clusters in ring N (1-3) or all rings
  --cluster <name>      Check a specific cluster by name
  --context <ctx>       Use a specific kubeconfig context (default: current)
                        In multi-cluster mode (--ring), overrides per-cluster
                        context resolution for all targets
  --summary             One-line-per-cluster table for quick comparison
  --verify              Run extended post-upgrade checks (pruner, marketplace)
  --pr-overwatch <url>  Watch a GitHub PR until merge, then verify cluster health.
                        Polls the PR every 30s; once merged, runs health checks
                        in --wait mode until all pass. Combinable with --ring,
                        --cluster, --verify, --interval, --timeout.
  --watch               Re-run checks until Ctrl-C (mutually exclusive with --wait)
  --wait                Re-run checks until all pass, then exit
  --interval <sec>      Seconds between --watch/--wait iterations (default: 5)
  --timeout <sec>       Max seconds for --wait/--pr-overwatch health checks
                        before failing (default: no limit)
  --json                Output results as JSON (implies no colors)
  --diag-dir <path>     Directory for diagnostic logs (default: \$TMPDIR/ring-status-diag)
  --repo-path <path>    Path to infra-deployments repo (overrides auto-detect)
  --version             Show version information
  --help                Show this help message

Examples:
  $(basename "$0")                          # current cluster context
  $(basename "$0") --ring 1                 # all ring-1 clusters
  $(basename "$0") --ring all               # all 9 clusters
  $(basename "$0") --ring all --summary     # compact table view
  $(basename "$0") --ring all --json        # machine-readable output
  $(basename "$0") --cluster stone-prod-p02 # specific cluster
  $(basename "$0") --verify                 # full post-upgrade checks
  $(basename "$0") --verify --wait          # retry until post-upgrade checks pass
  $(basename "$0") --verify --watch         # refresh checks until Ctrl-C
  $(basename "$0") --wait --interval 10 --timeout 600
  $(basename "$0") --context admin-ctx      # use specific kubeconfig context
  $(basename "$0") --wait --diag-dir ./logs # diagnostic logs written to ./logs/
  $(basename "$0") --pr-overwatch https://github.com/org/repo/pull/1234
  $(basename "$0") --pr-overwatch https://github.com/org/repo/pull/1234 --ring 1
  $(basename "$0") --pr-overwatch https://github.com/org/repo/pull/1234 --timeout 900

Multi-cluster context resolution:
  When --ring is used without --context, the script attempts to use each
  cluster name as a kubeconfig context. Ensure your kubeconfig has contexts
  matching the cluster names in ring-mappings.yaml, or use --context to
  force a single context for all targets.

Environment:
  INFRA_DEPLOYMENTS_PATH   Alternative to --repo-path for locating ring-mappings.yaml

Health checks performed:
  1. CatalogSource (custom-operators) — image SHA + connection state
  2. TektonConfig (config) — Ready status + reason
  3. Operator Subscription — current CSV version
  4. Pod health in openshift-pipelines — total + unhealthy count
  5. tekton-events-controller — running status + memory limit
  6. Pipelines as Code controller — image SHA
  7. Component health — per-workload readiness for all expected
     deployments and statefulsets (PaC components discovered by prefix)
  8. tekton-resource-pruner CronJob — last job status  (--verify only)
  9. Marketplace pods health                            (--verify only)

PR Overwatch (--pr-overwatch):
  Two-phase automated workflow:
    Phase 1 — polls the GitHub PR every 30s until it is merged (or closed).
    Phase 2 — runs health checks in --wait mode until all pass.
  Designed to be started and left running in the background so you get
  automatic post-merge verification. Combine with --ring or --cluster to
  target specific clusters, and --timeout to cap the health-check phase.
  Tip: background with  nohup ./ring-status.sh --pr-overwatch <url> &

Diagnostic logging:
  When any check fails, the script automatically captures detailed diagnostic
  information (raw errors, alternative resource lookups, RBAC checks, namespace
  scans) into a timestamped log file. The log path is printed after each failed
  iteration so you can inspect root causes without re-running manually.

Cross-cluster comparison (when checking multiple clusters):
  After individual checks, the script compares CatalogSource SHAs,
  Subscription CSVs, and PaC controller SHAs across all checked clusters
  to detect drift between rings or missed rollouts.

Requires:
  oc    OpenShift CLI
  yq    Mike Farah's yq v4+ (https://github.com/mikefarah/yq)
  jq    Required for --json and --pr-overwatch (https://github.com/jqlang/jq)
  gh    Required for --pr-overwatch (https://cli.github.com)
EOF
}

# ── Argument Parsing ─────────────────────────────────────────────────────────
parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ring)
        ARG_RING="${2:-}"
        [[ -z "$ARG_RING" ]] && { echo "Error: --ring requires a value (1, 2, 3, or all)" >&2; exit 1; }
        shift 2
        ;;
      --cluster)
        ARG_CLUSTER="${2:-}"
        [[ -z "$ARG_CLUSTER" ]] && { echo "Error: --cluster requires a cluster name" >&2; exit 1; }
        shift 2
        ;;
      --context)
        ARG_CONTEXT="${2:-}"
        [[ -z "$ARG_CONTEXT" ]] && { echo "Error: --context requires a context name" >&2; exit 1; }
        shift 2
        ;;
      --summary)
        ARG_SUMMARY=true
        shift
        ;;
      --verify)
        ARG_VERIFY=true
        shift
        ;;
      --watch)
        ARG_WATCH=true
        shift
        ;;
      --wait)
        ARG_WAIT=true
        shift
        ;;
      --interval)
        ARG_INTERVAL="${2:-}"
        [[ -z "$ARG_INTERVAL" ]] && { echo "Error: --interval requires a value in seconds" >&2; exit 1; }
        if ! [[ "$ARG_INTERVAL" =~ ^[1-9][0-9]*$ ]]; then
          echo "Error: --interval must be a positive integer" >&2
          exit 1
        fi
        shift 2
        ;;
      --timeout)
        ARG_TIMEOUT="${2:-}"
        [[ -z "$ARG_TIMEOUT" ]] && { echo "Error: --timeout requires a value in seconds" >&2; exit 1; }
        if ! [[ "$ARG_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
          echo "Error: --timeout must be a positive integer" >&2
          exit 1
        fi
        shift 2
        ;;
      --json)
        ARG_JSON=true
        RED='' GREEN='' YELLOW='' CYAN='' BOLD='' DIM='' RESET=''
        shift
        ;;
      --pr-overwatch)
        ARG_PR_URL="${2:-}"
        [[ -z "$ARG_PR_URL" ]] && { echo "Error: --pr-overwatch requires a GitHub PR URL" >&2; exit 1; }
        shift 2
        ;;
      --diag-dir)
        ARG_DIAG_DIR="${2:-}"
        [[ -z "$ARG_DIAG_DIR" ]] && { echo "Error: --diag-dir requires a path" >&2; exit 1; }
        shift 2
        ;;
      --repo-path)
        ARG_REPO_PATH="${2:-}"
        [[ -z "$ARG_REPO_PATH" ]] && { echo "Error: --repo-path requires a path" >&2; exit 1; }
        shift 2
        ;;
      --version)
        echo "ring-status ${VERSION}"
        exit 0
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        echo "Error: unknown option '$1'" >&2
        echo "Run '$(basename "$0") --help' for usage." >&2
        exit 1
        ;;
    esac
  done

  if [[ "$ARG_WATCH" == true && "$ARG_WAIT" == true ]]; then
    echo "Error: --watch and --wait are mutually exclusive" >&2
    exit 1
  fi
  if [[ "$ARG_WATCH" == true && "$ARG_JSON" == true ]]; then
    echo "Error: --watch cannot be combined with --json" >&2
    exit 1
  fi
  if [[ -n "$ARG_PR_URL" && ("$ARG_WATCH" == true || "$ARG_WAIT" == true) ]]; then
    echo "Error: --pr-overwatch cannot be combined with --watch or --wait" >&2
    exit 1
  fi
  if [[ "$ARG_TIMEOUT" -gt 0 && "$ARG_WAIT" != true && -z "$ARG_PR_URL" ]]; then
    echo "Error: --timeout requires --wait or --pr-overwatch" >&2
    exit 1
  fi
}

# ── Helpers ──────────────────────────────────────────────────────────────────
pass()  { printf "${GREEN}✓${RESET} %s\n" "$*"; }
fail()  { printf "${RED}✗${RESET} %s\n" "$*"; }
warn()  { printf "${YELLOW}⚠${RESET} %s\n" "$*"; }
info()  { printf "${CYAN}→${RESET} %s\n" "$*"; }
header() { printf "\n${BOLD}%s${RESET}\n" "$*"; }

# Run an oc command with a timeout.
# Uses CURRENT_TARGET_CTX (set per-cluster in the main loop), falling back to
# ARG_CONTEXT (the global --context flag), falling back to the default context.
run_oc() {
  local ctx_args=()
  if [[ -n "$CURRENT_TARGET_CTX" ]]; then
    ctx_args=(--context "$CURRENT_TARGET_CTX")
  elif [[ -n "$ARG_CONTEXT" ]]; then
    ctx_args=(--context "$ARG_CONTEXT")
  fi
  timeout "${OC_TIMEOUT}s" oc "${ctx_args[@]}" "$@" 2>/dev/null
}

# ── Diagnostic Log ────────────────────────────────────────────────────────
# When a health check fails, these helpers capture detailed root-cause
# information into a timestamped log file so operators can inspect the
# "why" without manually re-running oc commands.

init_diag_log() {
  [[ -n "$DIAG_LOG" ]] && return
  local dir="${ARG_DIAG_DIR:-$DIAG_LOG_DIR}"
  mkdir -p "$dir" 2>/dev/null || { echo "Warning: cannot create diag dir: $dir" >&2; return; }
  DIAG_LOG="${dir}/diag-$(date +%Y%m%dT%H%M%S)-$$.log"
  : > "$DIAG_LOG"
  DIAG_HAS_ENTRIES=false
}

diag() {
  [[ -z "$DIAG_LOG" ]] && return
  printf '%s\n' "$*" >> "$DIAG_LOG"
  DIAG_HAS_ENTRIES=true
}

diag_section() {
  [[ -z "$DIAG_LOG" ]] && return
  printf '\n══ %s (%s) ══\n' "$1" "$(date -Iseconds 2>/dev/null || date)" >> "$DIAG_LOG"
  DIAG_HAS_ENTRIES=true
}

# Run an oc command and log both stdout and stderr into the diagnostic log.
diag_cmd() {
  [[ -z "$DIAG_LOG" ]] && return
  local label="$1"; shift
  diag "  ── ${label}"
  diag "  \$ $*"
  local cmd_out
  cmd_out=$("$@" 2>&1) || true
  if [[ -n "$cmd_out" ]]; then
    printf '%s\n' "$cmd_out" | sed 's/^/    /' >> "$DIAG_LOG"
  else
    diag "    (no output)"
  fi
}

# Print the log path only if diagnostics were actually captured.
print_diag_link() {
  if [[ -n "$DIAG_LOG" && "$DIAG_HAS_ENTRIES" == true && -s "$DIAG_LOG" ]]; then
    info "Diagnostic log: ${BOLD}${DIAG_LOG}${RESET}"
  fi
}

# Like run_oc but preserves stderr for diagnostic capture.
run_oc_capture() {
  local ctx_args=()
  if [[ -n "$CURRENT_TARGET_CTX" ]]; then
    ctx_args=(--context "$CURRENT_TARGET_CTX")
  elif [[ -n "$ARG_CONTEXT" ]]; then
    ctx_args=(--context "$ARG_CONTEXT")
  fi
  timeout "${OC_TIMEOUT}s" oc "${ctx_args[@]}" "$@" 2>&1
}

# ── Per-Check Diagnostic Functions ───────────────────────────────────────
# Called by each check_* function on failure to populate the diagnostic log
# with actionable root-cause information.

diag_subscription() {
  local cluster="${1:-current}"
  init_diag_log
  diag_section "Subscription: unreachable or not found — ${cluster}"

  diag "Expected: subscription/openshift-pipelines-operator in openshift-operators"
  diag ""

  # Capture the raw error (run_oc swallows stderr)
  diag "  ── Raw error output"
  diag "  \$ oc get subscription openshift-pipelines-operator -n openshift-operators"
  local raw_err
  raw_err=$(run_oc_capture get subscription openshift-pipelines-operator -n openshift-operators \
    -o jsonpath='{.status.currentCSV}' 2>&1) || true
  diag "    ${raw_err:-(empty)}"

  # List all subscriptions across likely namespaces
  local ns
  for ns in openshift-operators openshift-pipelines tekton-pipelines; do
    diag_cmd "All subscriptions in ${ns}" \
      run_oc_capture get subscriptions.operators.coreos.com -n "$ns" \
        -o custom-columns='NAME:.metadata.name,PACKAGE:.spec.name,CSV:.status.currentCSV' \
        --no-headers
  done

  # Check if the Subscription CRD exists at all
  diag_cmd "Subscription CRD check" \
    run_oc_capture get crd subscriptions.operators.coreos.com -o name

  # RBAC: can the current user even read subscriptions?
  diag_cmd "RBAC: can-i get subscriptions in openshift-operators" \
    run_oc_capture auth can-i get subscriptions.operators.coreos.com -n openshift-operators

  # Check whether the operator is installed via a different mechanism
  diag_cmd "ClusterServiceVersions matching 'pipeline'" \
    run_oc_capture get csv -n openshift-operators -o custom-columns='NAME:.metadata.name,PHASE:.status.phase' \
      --no-headers

  # Check for operator pods directly (proves operator is running even without a subscription)
  diag_cmd "Operator pods in openshift-pipelines" \
    run_oc_capture get pods -n openshift-pipelines -o custom-columns='NAME:.metadata.name,STATUS:.status.phase' \
      --no-headers

  diag ""
  diag "Likely root cause: the Subscription resource name or namespace differs"
  diag "from the expected 'openshift-pipelines-operator' in 'openshift-operators'."
  diag "On staging/dev clusters, operators are often installed via managed add-ons"
  diag "or TektonConfig rather than OLM Subscriptions."
}

diag_catalog_source() {
  local cluster="${1:-current}"
  init_diag_log
  diag_section "CatalogSource: unreachable or not found — ${cluster}"

  diag "Expected: catalogsource/custom-operators in openshift-marketplace"
  diag ""

  diag_cmd "Raw error output" \
    run_oc_capture get catalogsource custom-operators -n openshift-marketplace \
      -o jsonpath='{.spec.image}{"|"}{.status.connectionState.lastObservedState}'

  diag_cmd "All CatalogSources in openshift-marketplace" \
    run_oc_capture get catalogsource -n openshift-marketplace \
      -o custom-columns='NAME:.metadata.name,STATE:.status.connectionState.lastObservedState' \
      --no-headers

  diag_cmd "openshift-marketplace namespace exists" \
    run_oc_capture get namespace openshift-marketplace -o name

  diag_cmd "RBAC: can-i get catalogsources" \
    run_oc_capture auth can-i get catalogsources.operators.coreos.com -n openshift-marketplace
}

diag_tekton_config() {
  local cluster="${1:-current}"
  init_diag_log
  diag_section "TektonConfig: unreachable or not found — ${cluster}"

  diag "Expected: tektonconfig/config"
  diag ""

  diag_cmd "Raw error output" \
    run_oc_capture get tektonconfig config -o yaml

  diag_cmd "All TektonConfig resources" \
    run_oc_capture get tektonconfig -o custom-columns='NAME:.metadata.name' --no-headers

  diag_cmd "TektonConfig CRD check" \
    run_oc_capture get crd tektonconfigs.operator.tekton.dev -o name
}

diag_pod_health() {
  local cluster="${1:-current}"
  init_diag_log
  diag_section "Pod health: failure — ${cluster}"

  diag_cmd "All pods in openshift-pipelines (wide)" \
    run_oc_capture get pods -n openshift-pipelines -o wide

  diag_cmd "Unhealthy pods details" \
    run_oc_capture get pods -n openshift-pipelines \
      --field-selector='status.phase!=Running,status.phase!=Succeeded' \
      -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,REASON:.status.reason' \
      --no-headers

  diag_cmd "Recent events in openshift-pipelines" \
    run_oc_capture get events -n openshift-pipelines --sort-by=.lastTimestamp \
      -o custom-columns='TIME:.lastTimestamp,TYPE:.type,REASON:.reason,MSG:.message' \
      --no-headers
}

diag_events_controller() {
  local cluster="${1:-current}"
  init_diag_log
  diag_section "tekton-events-controller: failure — ${cluster}"

  diag_cmd "Deployment details" \
    run_oc_capture get deployment tekton-events-controller -n openshift-pipelines -o yaml

  diag_cmd "TektonConfig events-controller spec" \
    run_oc_capture get tektonconfig config \
      -o jsonpath='{.spec.pipeline.options.deployments.tekton-events-controller}'

  diag_cmd "All deployments in openshift-pipelines" \
    run_oc_capture get deployments -n openshift-pipelines \
      -o custom-columns='NAME:.metadata.name,READY:.status.readyReplicas,REPLICAS:.status.replicas' \
      --no-headers
}

diag_pac_controller() {
  local cluster="${1:-current}"
  init_diag_log
  diag_section "PaC controller: failure — ${cluster}"

  diag_cmd "Deployment details" \
    run_oc_capture get deployment pipelines-as-code-controller -n openshift-pipelines -o yaml

  diag_cmd "All PaC deployments" \
    run_oc_capture get deployments -n openshift-pipelines -l app.kubernetes.io/part-of=pipelines-as-code \
      -o custom-columns='NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image' \
      --no-headers
}

diag_component_health() {
  local cluster="${1:-current}"
  init_diag_log
  diag_section "Component health: one or more workloads unhealthy — ${cluster}"

  diag_cmd "All deployments in openshift-pipelines" \
    run_oc_capture get deployments -n openshift-pipelines \
      -o custom-columns='NAME:.metadata.name,READY:.status.readyReplicas,DESIRED:.spec.replicas,AVAILABLE:.status.availableReplicas,UP-TO-DATE:.status.updatedReplicas' \
      --no-headers

  diag_cmd "All statefulsets in openshift-pipelines" \
    run_oc_capture get statefulsets -n openshift-pipelines \
      -o custom-columns='NAME:.metadata.name,READY:.status.readyReplicas,DESIRED:.spec.replicas' \
      --no-headers

  diag_cmd "Pods not in Running/Succeeded phase" \
    run_oc_capture get pods -n openshift-pipelines \
      --field-selector='status.phase!=Running,status.phase!=Succeeded' \
      -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,NODE:.spec.nodeName,RESTARTS:.status.containerStatuses[0].restartCount' \
      --no-headers

  diag_cmd "Recent warning events in openshift-pipelines" \
    run_oc_capture get events -n openshift-pipelines --field-selector type=Warning \
      --sort-by=.lastTimestamp \
      -o custom-columns='TIME:.lastTimestamp,OBJECT:.involvedObject.name,REASON:.reason,MSG:.message' \
      --no-headers
}

# ── Ring/Cluster Resolution ─────────────────────────────────────────────────
resolve_rings_file() {
  if [[ -n "$ARG_REPO_PATH" ]]; then
    RINGS_FILE="${ARG_REPO_PATH}/components/pipeline-service/production/ring-mappings.yaml"
  elif [[ -n "${INFRA_DEPLOYMENTS_PATH:-}" ]]; then
    RINGS_FILE="${INFRA_DEPLOYMENTS_PATH}/components/pipeline-service/production/ring-mappings.yaml"
  fi

  if [[ ! -f "$RINGS_FILE" ]]; then
    echo "Error: ring-mappings.yaml not found at: $RINGS_FILE" >&2
    echo "Use --repo-path or set INFRA_DEPLOYMENTS_PATH." >&2
    exit 1
  fi
}

get_clusters_for_ring() {
  local ring="$1"
  yq eval ".ring-${ring}[]" "$RINGS_FILE" 2>/dev/null
}

get_all_rings() {
  yq eval 'keys | .[]' "$RINGS_FILE" 2>/dev/null
}

get_ring_for_cluster() {
  local cluster="$1"
  for ring in $(get_all_rings); do
    if yq eval ".${ring}[]" "$RINGS_FILE" 2>/dev/null | grep -qx "$cluster"; then
      echo "$ring"
      return
    fi
  done
  echo "unknown"
}

validate_cluster_exists() {
  local cluster="$1"
  local all_clusters
  all_clusters=$(yq eval '.[] | .[]' "$RINGS_FILE" 2>/dev/null)
  if ! echo "$all_clusters" | grep -qx "$cluster"; then
    echo "Error: cluster '$cluster' not found in ring-mappings.yaml" >&2
    echo "Known clusters:" >&2
    echo "$all_clusters" | sed 's/^/  /' >&2
    exit 1
  fi
}

# Build the list of clusters to check and their ring assignments.
# Sets the global TARGETS array of "ring:cluster" pairs.
declare -a TARGETS=()

resolve_targets() {
  if [[ -n "$ARG_CLUSTER" ]]; then
    validate_cluster_exists "$ARG_CLUSTER"
    local ring
    ring=$(get_ring_for_cluster "$ARG_CLUSTER")
    TARGETS=("${ring}:${ARG_CLUSTER}")
    return
  fi

  if [[ -n "$ARG_RING" ]]; then
    if [[ "$ARG_RING" == "all" ]]; then
      for ring in $(get_all_rings); do
        local ring_num="${ring#ring-}"
        while IFS= read -r cluster; do
          [[ -n "$cluster" ]] && TARGETS+=("${ring}:${cluster}")
        done < <(get_clusters_for_ring "$ring_num")
      done
    else
      if ! [[ "$ARG_RING" =~ ^[1-9][0-9]*$ ]]; then
        echo "Error: --ring value must be a number (1, 2, 3, ...) or 'all'" >&2
        exit 1
      fi
      local clusters
      clusters=$(get_clusters_for_ring "$ARG_RING")
      if [[ -z "$clusters" ]]; then
        echo "Error: ring-${ARG_RING} not found in ring-mappings.yaml" >&2
        exit 1
      fi
      while IFS= read -r cluster; do
        [[ -n "$cluster" ]] && TARGETS+=("ring-${ARG_RING}:${cluster}")
      done <<< "$clusters"
    fi
    return
  fi

  # No --ring or --cluster: use the current context
  TARGETS=("current-context:current")
}

# ── Context Resolution ──────────────────────────────────────────────────────
# Determine the kubeconfig context to use for a given cluster target.
# --context overrides everything; otherwise named clusters use their name as
# the context (assumes kubeconfig contexts match cluster names).
resolve_cluster_context() {
  local cluster="$1"
  if [[ -n "$ARG_CONTEXT" ]]; then
    CURRENT_TARGET_CTX="$ARG_CONTEXT"
  elif [[ "$cluster" != "current" ]]; then
    CURRENT_TARGET_CTX="$cluster"
  else
    CURRENT_TARGET_CTX=""
  fi
}

# ── Cross-Cluster Comparison Data ───────────────────────────────────────────
# Populated during checks; used by print_drift_report.
declare -A OBSERVED_CSV=()
declare -A OBSERVED_CATSRC_SHA=()
declare -A OBSERVED_PAC_SHA=()

# ── Health Check Functions ──────────────────────────────────────────────────
# Each check_* function prints its results and returns:
#   0 = pass, 1 = fail, 2 = warn
# Functions that collect comparison data accept an optional cluster name.

declare -A SUMMARY_DATA=()

check_catalog_source() {
  local cluster="${1:-}"
  local output
  if ! output=$(run_oc get catalogsource custom-operators -n openshift-marketplace \
    -o jsonpath='{.spec.image}{"|"}{.status.connectionState.lastObservedState}' 2>&1); then
    fail "CatalogSource: unreachable or not found"
    diag_catalog_source "$cluster"
    return 1
  fi

  local image state
  image="${output%%|*}"
  state="${output##*|}"
  local sha="${image##*@}"

  [[ -n "$cluster" ]] && OBSERVED_CATSRC_SHA["$cluster"]="$sha"

  if [[ "$state" == "READY" ]]; then
    pass "CatalogSource: ${GREEN}READY${RESET}  sha=${DIM}${sha:0:16}…${RESET}"
    return 0
  else
    fail "CatalogSource: state=${RED}${state:-UNKNOWN}${RESET}  sha=${sha:0:16}…"
    return 1
  fi
}

check_tekton_config() {
  local output
  if ! output=$(run_oc get tektonconfig config \
    -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{"|"}{.reason}{"|"}{.message}{end}' 2>&1); then
    fail "TektonConfig: unreachable or not found"
    diag_tekton_config
    return 1
  fi

  local status reason message
  status="${output%%|*}"
  local rest="${output#*|}"
  reason="${rest%%|*}"
  message="${rest#*|}"

  if [[ "$status" == "True" ]]; then
    pass "TektonConfig: ${GREEN}Ready${RESET}  reason=${reason:-OK}"
    return 0
  elif [[ "$status" == "False" ]]; then
    fail "TektonConfig: ${RED}Not Ready${RESET}  reason=${reason}  ${message:0:80}"
    return 1
  else
    warn "TektonConfig: status=${YELLOW}${status:-Unknown}${RESET}  reason=${reason}"
    return 2
  fi
}

check_subscription() {
  local cluster="${1:-}"
  local output
  if ! output=$(run_oc get subscription openshift-pipelines-operator -n openshift-operators \
    -o jsonpath='{.status.currentCSV}' 2>&1); then
    fail "Subscription: unreachable or not found"
    diag_subscription "$cluster"
    return 1
  fi

  [[ -n "$cluster" ]] && OBSERVED_CSV["$cluster"]="${output:-}"

  if [[ -n "$output" ]]; then
    pass "Subscription: CSV=${BOLD}${output}${RESET}"
    return 0
  else
    warn "Subscription: no currentCSV reported"
    return 2
  fi
}

check_pod_health() {
  local cluster="${1:-}"
  local output
  if ! output=$(run_oc get pods -n openshift-pipelines \
    -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>&1); then
    fail "Pod health: unable to list pods in openshift-pipelines"
    diag_pod_health "$cluster"
    return 1
  fi

  local total=0 unhealthy=0
  while IFS= read -r phase; do
    [[ -z "$phase" ]] && continue
    total=$(( total + 1 ))
    if [[ "$phase" != "Running" && "$phase" != "Succeeded" ]]; then
      unhealthy=$(( unhealthy + 1 ))
    fi
  done <<< "$output"

  if [[ $total -eq 0 ]]; then
    fail "Pod health: no pods found in openshift-pipelines"
    diag_pod_health "$cluster"
    return 1
  elif [[ $unhealthy -eq 0 ]]; then
    pass "Pod health: ${GREEN}${total}/${total} healthy${RESET}"
    return 0
  else
    fail "Pod health: ${RED}${unhealthy}/${total} unhealthy${RESET}"
    diag_pod_health "$cluster"
    return 1
  fi
}

check_events_controller() {
  local output
  if ! output=$(run_oc get deployment tekton-events-controller -n openshift-pipelines \
    -o jsonpath='{.status.readyReplicas}{"|"}{.status.replicas}{"|"}{.spec.template.spec.containers[0].resources.limits.memory}' 2>&1); then
    # The events controller may be managed via TektonConfig options rather than a standalone deployment.
    local tc_replicas
    tc_replicas=$(run_oc get tektonconfig config \
      -o jsonpath='{.spec.pipeline.options.deployments.tekton-events-controller.spec.replicas}' 2>/dev/null || true)

    if [[ "$tc_replicas" == "0" ]]; then
      pass "tekton-events-controller: ${DIM}scaled to 0 (expected)${RESET}"
      return 0
    fi

    fail "tekton-events-controller: deployment not found"
    diag_events_controller
    return 1
  fi

  local ready replicas mem_limit
  ready="${output%%|*}"
  local rest="${output#*|}"
  replicas="${rest%%|*}"
  mem_limit="${rest#*|}"

  if [[ "${replicas:-0}" == "0" ]]; then
    pass "tekton-events-controller: ${DIM}scaled to 0 (expected)${RESET}"
    return 0
  elif [[ "${ready:-0}" == "${replicas}" ]]; then
    pass "tekton-events-controller: ${GREEN}running${RESET} (${ready}/${replicas})  mem_limit=${mem_limit:-N/A}"
    return 0
  else
    fail "tekton-events-controller: ${RED}${ready:-0}/${replicas} ready${RESET}  mem_limit=${mem_limit:-N/A}"
    diag_events_controller
    return 1
  fi
}

check_pac_controller() {
  local cluster="${1:-}"
  local output
  if ! output=$(run_oc get deployment pipelines-as-code-controller -n openshift-pipelines \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>&1); then
    fail "PaC controller: deployment not found"
    diag_pac_controller "$cluster"
    return 1
  fi

  if [[ -z "$output" ]]; then
    warn "PaC controller: image field is empty"
    return 2
  fi

  local sha="${output##*@}"
  if [[ "$sha" == "$output" ]]; then
    sha="${output##*:}"
  fi

  if [[ -z "$sha" || "$sha" == "$output" ]]; then
    warn "PaC controller: unable to extract SHA from image: ${output:0:60}"
    return 2
  fi

  [[ -n "$cluster" ]] && OBSERVED_PAC_SHA["$cluster"]="$sha"

  pass "PaC controller: sha=${DIM}${sha:0:16}…${RESET}"
  return 0
}

# ── Per-Component Deployment/StatefulSet Health ────────────────────────────
# Verifies every expected pipeline-service workload is running and ready.
# Uses only 2 oc calls (bulk-list deployments + statefulsets) then checks
# each component locally.  PaC deployments are discovered by prefix so
# renamed deployments across versions are picked up automatically.

# Fixed-name deployments expected in openshift-pipelines.
# tekton-events-controller is excluded — it has its own dedicated check
# that handles the "scaled to 0" case.
EXPECTED_DEPLOYMENTS=(
  pipeline-metrics-exporter
  pipelines-console-plugin
  tekton-chains-controller
  tekton-operator-proxy-webhook
  tekton-pipelines-webhook
  tekton-triggers-controller
  tekton-triggers-core-interceptors
  tekton-triggers-webhook
  tkn-cli-serve
)

EXPECTED_STATEFULSETS=(
  tekton-pipelines-controller
  tekton-pipelines-remote-resolvers
)

check_component_health() {
  local cluster="${1:-}"
  local checked=0 healthy=0
  local -a failures=()

  # Bulk-fetch all deployments and statefulsets (2 oc calls total)
  local deploy_raw sts_raw
  if ! deploy_raw=$(run_oc get deployments -n openshift-pipelines \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.readyReplicas}{"|"}{.spec.replicas}{"\n"}{end}' 2>&1); then
    fail "Component health: unable to list deployments"
    diag_component_health "$cluster"
    return 1
  fi
  sts_raw=$(run_oc get statefulsets -n openshift-pipelines \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.readyReplicas}{"|"}{.spec.replicas}{"\n"}{end}' 2>/dev/null || echo "")

  # Build lookup maps: name → "readyReplicas|replicas"
  local -A deploy_map=() sts_map=()
  local line name rest
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    name="${line%%|*}"; rest="${line#*|}"
    deploy_map["$name"]="$rest"
  done <<< "$deploy_raw"

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    name="${line%%|*}"; rest="${line#*|}"
    sts_map["$name"]="$rest"
  done <<< "$sts_raw"

  # ── Fixed-name deployments ─────────────────────────────────────────────
  local deploy ready replicas
  for deploy in "${EXPECTED_DEPLOYMENTS[@]}"; do
    checked=$((checked + 1))
    if [[ -z "${deploy_map[$deploy]+_}" ]]; then
      failures+=("${deploy}: not found")
      continue
    fi
    IFS='|' read -r ready replicas <<< "${deploy_map[$deploy]}"
    ready="${ready:-0}"; replicas="${replicas:-0}"
    if [[ "$ready" == "$replicas" ]]; then
      healthy=$((healthy + 1))
    else
      failures+=("${deploy}: ${ready}/${replicas} ready")
    fi
  done

  # ── PaC deployments (prefix-discovered) ────────────────────────────────
  local pac_found=false
  for name in "${!deploy_map[@]}"; do
    [[ "$name" != pipelines-as-code-* ]] && continue
    pac_found=true
    checked=$((checked + 1))
    IFS='|' read -r ready replicas <<< "${deploy_map[$name]}"
    ready="${ready:-0}"; replicas="${replicas:-0}"
    if [[ "$ready" == "$replicas" ]]; then
      healthy=$((healthy + 1))
    else
      failures+=("${name}: ${ready}/${replicas} ready")
    fi
  done
  if [[ "$pac_found" == false ]]; then
    checked=$((checked + 1))
    failures+=("pipelines-as-code-*: no PaC deployments discovered")
  fi

  # ── StatefulSets ───────────────────────────────────────────────────────
  local sts
  for sts in "${EXPECTED_STATEFULSETS[@]}"; do
    checked=$((checked + 1))
    if [[ -z "${sts_map[$sts]+_}" ]]; then
      failures+=("${sts} (sts): not found")
      continue
    fi
    IFS='|' read -r ready replicas <<< "${sts_map[$sts]}"
    ready="${ready:-0}"; replicas="${replicas:-0}"
    if [[ "$ready" == "$replicas" ]]; then
      healthy=$((healthy + 1))
    else
      failures+=("${sts} (sts): ${ready}/${replicas} ready")
    fi
  done

  # ── Result ─────────────────────────────────────────────────────────────
  if [[ ${#failures[@]} -eq 0 ]]; then
    pass "Component health: ${GREEN}${healthy}/${checked} workloads ready${RESET}"
    return 0
  else
    fail "Component health: ${RED}${healthy}/${checked} workloads ready${RESET}"
    local f
    for f in "${failures[@]}"; do
      printf "    ${RED}✗${RESET} %s\n" "$f"
    done
    diag_component_health "$cluster"
    return 1
  fi
}

# ── Extended Checks (--verify only) ─────────────────────────────────────────
check_pruner_cronjob() {
  local output
  if ! output=$(run_oc get cronjob tekton-resource-pruner -n openshift-pipelines \
    -o jsonpath='{.status.lastScheduleTime}{"|"}{.status.conditions[0].type}{"|"}{.status.conditions[0].status}' 2>&1); then
    local cronjobs
    cronjobs=$(run_oc get cronjobs -n openshift-pipelines -o name 2>/dev/null || true)
    if [[ -z "$cronjobs" ]]; then
      warn "Pruner CronJob: no CronJobs found in openshift-pipelines"
      return 2
    fi

    local pruner_name
    pruner_name=$(echo "$cronjobs" | grep -i "prun" | head -1 || true)
    if [[ -z "$pruner_name" ]]; then
      warn "Pruner CronJob: no pruner CronJob found (found: $(echo "$cronjobs" | tr '\n' ' '))"
      return 2
    fi

    local last_time
    last_time=$(run_oc get "$pruner_name" -n openshift-pipelines \
      -o jsonpath='{.status.lastScheduleTime}' 2>/dev/null || true)

    # CronJobs own their Jobs via ownerReferences; filter by the CronJob name.
    local cj_short="${pruner_name##*/}"
    local last_job_succeeded
    last_job_succeeded=$(run_oc get jobs -n openshift-pipelines \
      --sort-by=.metadata.creationTimestamp \
      -o jsonpath="{.items[?(@.metadata.ownerReferences[0].name==\"${cj_short}\")].status.succeeded}" \
      2>/dev/null | awk '{print $NF}' || true)

    if [[ "${last_job_succeeded:-0}" == "1" ]]; then
      pass "Pruner (${cj_short}): last run=${last_time:-unknown} ${GREEN}succeeded${RESET}"
      return 0
    elif [[ -n "$last_time" ]]; then
      warn "Pruner (${cj_short}): last run=${last_time}  status=${last_job_succeeded:-unknown}"
      return 2
    else
      warn "Pruner (${cj_short}): never scheduled"
      return 2
    fi
  fi

  local last_time cond_type cond_status
  last_time="${output%%|*}"
  local rest="${output#*|}"
  cond_type="${rest%%|*}"
  cond_status="${rest#*|}"

  if [[ -n "$last_time" ]]; then
    pass "Pruner CronJob: last=${last_time}  ${cond_type:-status}=${cond_status:-OK}"
    return 0
  else
    warn "Pruner CronJob: never scheduled"
    return 2
  fi
}

check_marketplace_pods() {
  local output
  if ! output=$(run_oc get pods -n openshift-marketplace \
    -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.phase}{"\n"}{end}' 2>&1); then
    fail "Marketplace pods: unable to list pods"
    return 1
  fi

  local total=0 unhealthy=0 unhealthy_names=""
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local name phase
    name="${line%%|*}"
    phase="${line##*|}"
    total=$(( total + 1 ))
    if [[ "$phase" != "Running" && "$phase" != "Succeeded" ]]; then
      unhealthy=$(( unhealthy + 1 ))
      unhealthy_names+="  ${name} (${phase})\n"
    fi
  done <<< "$output"

  if [[ $total -eq 0 ]]; then
    warn "Marketplace pods: no pods found"
    return 2
  elif [[ $unhealthy -eq 0 ]]; then
    pass "Marketplace pods: ${GREEN}${total}/${total} healthy${RESET}"
    return 0
  else
    fail "Marketplace pods: ${RED}${unhealthy}/${total} unhealthy${RESET}"
    printf "${unhealthy_names}"
    return 1
  fi
}

# ── Run All Checks for a Single Cluster ─────────────────────────────────────
run_checks() {
  local cluster="$1"
  local ring="$2"
  local passes=0 fails=0 warns=0

  count_result() {
    local rc=$1
    case $rc in
      0) passes=$(( passes + 1 )) ;;
      1) fails=$(( fails + 1 )) ;;
      2) warns=$(( warns + 1 )) ;;
    esac
  }

  check_catalog_source "$cluster";  count_result $?
  check_tekton_config;              count_result $?
  check_subscription "$cluster";    count_result $?
  check_pod_health "$cluster";      count_result $?
  check_events_controller;          count_result $?
  check_pac_controller "$cluster";  count_result $?
  check_component_health "$cluster"; count_result $?

  if [[ "$ARG_VERIFY" == true ]]; then
    check_pruner_cronjob;           count_result $?
    check_marketplace_pods;         count_result $?
  fi

  local total=$((passes + fails + warns))
  echo ""
  if [[ $fails -eq 0 && $warns -eq 0 ]]; then
    printf "  ${GREEN}${BOLD}All %d checks passed${RESET}\n" "$total"
  else
    printf "  Results: ${GREEN}%d passed${RESET}  ${RED}%d failed${RESET}  ${YELLOW}%d warnings${RESET}\n" \
      "$passes" "$fails" "$warns"
  fi

  SUMMARY_DATA["${ring}:${cluster}"]="${passes}:${fails}:${warns}:${total}"

  [[ $fails -gt 0 ]] && return 1
  return 0
}

# ── Summary Mode Checks (one-liner per cluster) ────────────────────────────
# Color codes are applied around pre-padded visible text so printf width
# specifiers count only printable characters and columns align correctly.
run_summary_check() {
  local cluster="$1"
  local ring="$2"

  # CatalogSource — fetch state and image SHA in one call
  local cs_output cs_text cs_color
  cs_output=$(run_oc get catalogsource custom-operators -n openshift-marketplace \
    -o jsonpath='{.status.connectionState.lastObservedState}{"|"}{.spec.image}' 2>/dev/null || echo "ERR|")
  local cs_state="${cs_output%%|*}"
  local cs_image="${cs_output##*|}"
  if [[ "$cs_state" == "READY" ]]; then
    cs_text="RDY"; cs_color="$GREEN"
  else
    cs_text="${cs_state:0:3}"; cs_color="$RED"
  fi
  [[ -n "$cluster" ]] && OBSERVED_CATSRC_SHA["$cluster"]="${cs_image##*@}"

  # TektonConfig
  local tc_ready tc_text tc_color
  tc_ready=$(run_oc get tektonconfig config \
    -o jsonpath='{range .status.conditions[?(@.type=="Ready")]}{.status}{end}' 2>/dev/null || echo "ERR")
  if [[ "$tc_ready" == "True" ]]; then
    tc_text="RDY"; tc_color="$GREEN"
  else
    tc_text="${tc_ready:0:3}"; tc_color="$RED"
  fi

  # Subscription CSV
  local csv
  csv=$(run_oc get subscription openshift-pipelines-operator -n openshift-operators \
    -o jsonpath='{.status.currentCSV}' 2>/dev/null || echo "ERR")
  csv="${csv:-N/A}"
  [[ -n "$cluster" ]] && OBSERVED_CSV["$cluster"]="$csv"
  if [[ ${#csv} -gt 30 ]]; then
    csv="${csv:0:27}..."
  fi

  # Pod health
  local pod_output total_pods=0 unhealthy_pods=0
  pod_output=$(run_oc get pods -n openshift-pipelines \
    -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null || echo "")
  while IFS= read -r phase; do
    [[ -z "$phase" ]] && continue
    total_pods=$(( total_pods + 1 ))
    if [[ "$phase" != "Running" && "$phase" != "Succeeded" ]]; then
      unhealthy_pods=$(( unhealthy_pods + 1 ))
    fi
  done <<< "$pod_output"
  local pods_text pods_color
  if [[ $unhealthy_pods -eq 0 && $total_pods -gt 0 ]]; then
    pods_text="${total_pods}/${total_pods}"; pods_color="$GREEN"
  elif [[ $total_pods -eq 0 ]]; then
    pods_text="0"; pods_color="$RED"
  else
    pods_text="$((total_pods-unhealthy_pods))/${total_pods}"; pods_color="$RED"
  fi

  # Events controller
  local evt_text evt_color
  local evt_replicas
  evt_replicas=$(run_oc get deployment tekton-events-controller -n openshift-pipelines \
    -o jsonpath='{.status.replicas}' 2>/dev/null || echo "")
  if [[ -z "$evt_replicas" || "$evt_replicas" == "0" ]]; then
    evt_text="off"; evt_color="$DIM"
  else
    local evt_ready
    evt_ready=$(run_oc get deployment tekton-events-controller -n openshift-pipelines \
      -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    if [[ "${evt_ready:-0}" == "$evt_replicas" ]]; then
      evt_text="ok"; evt_color="$GREEN"
    else
      evt_text="${evt_ready:-0}/${evt_replicas}"; evt_color="$RED"
    fi
  fi

  printf "  %-6s  %-20s  %b%-5s%b  %b%-5s%b  %-32s  %b%-7s%b  %b%-5s%b\n" \
    "$ring" "$cluster" \
    "$cs_color" "$cs_text" "$RESET" \
    "$tc_color" "$tc_text" "$RESET" \
    "$csv" \
    "$pods_color" "$pods_text" "$RESET" \
    "$evt_color" "$evt_text" "$RESET"
}

# ── Cross-Cluster Drift Detection ──────────────────────────────────────────
print_drift_report() {
  local has_drift=false

  # CSV comparison
  if [[ ${#OBSERVED_CSV[@]} -gt 1 ]]; then
    local -A csv_groups=()
    for cluster in "${!OBSERVED_CSV[@]}"; do
      local val="${OBSERVED_CSV[$cluster]}"
      csv_groups["$val"]+="${cluster} "
    done
    if [[ ${#csv_groups[@]} -gt 1 ]]; then
      has_drift=true
      header "⚠ CSV Drift Detected"
      for val in "${!csv_groups[@]}"; do
        printf "  ${BOLD}%s${RESET}: %s\n" "$val" "${csv_groups[$val]}"
      done
    fi
  fi

  # CatalogSource SHA comparison
  if [[ ${#OBSERVED_CATSRC_SHA[@]} -gt 1 ]]; then
    local -A sha_groups=()
    for cluster in "${!OBSERVED_CATSRC_SHA[@]}"; do
      local val="${OBSERVED_CATSRC_SHA[$cluster]}"
      sha_groups["$val"]+="${cluster} "
    done
    if [[ ${#sha_groups[@]} -gt 1 ]]; then
      has_drift=true
      header "⚠ CatalogSource SHA Drift Detected"
      for val in "${!sha_groups[@]}"; do
        printf "  ${DIM}%s…${RESET}: %s\n" "${val:0:16}" "${sha_groups[$val]}"
      done
    fi
  fi

  # PaC SHA comparison
  if [[ ${#OBSERVED_PAC_SHA[@]} -gt 1 ]]; then
    local -A pac_groups=()
    for cluster in "${!OBSERVED_PAC_SHA[@]}"; do
      local val="${OBSERVED_PAC_SHA[$cluster]}"
      pac_groups["$val"]+="${cluster} "
    done
    if [[ ${#pac_groups[@]} -gt 1 ]]; then
      has_drift=true
      header "⚠ PaC Controller SHA Drift Detected"
      for val in "${!pac_groups[@]}"; do
        printf "  ${DIM}%s…${RESET}: %s\n" "${val:0:16}" "${pac_groups[$val]}"
      done
    fi
  fi

  if [[ "$has_drift" == false && ${#OBSERVED_CSV[@]} -gt 1 ]]; then
    echo ""
    pass "No drift detected — all checked clusters report identical CSVs and SHAs"
  fi
}

# ── JSON Output ─────────────────────────────────────────────────────────────
declare -a JSON_RESULTS=()

build_cluster_json() {
  local cluster="$1" ring="$2" data="$3"
  local p f w t
  IFS=: read -r p f w t <<< "$data"

  local csv_val="${OBSERVED_CSV[$cluster]:-}"
  local catsrc_sha="${OBSERVED_CATSRC_SHA[$cluster]:-}"
  local pac_sha="${OBSERVED_PAC_SHA[$cluster]:-}"
  local status="pass"
  [[ $w -gt 0 ]] && status="warn"
  [[ $f -gt 0 ]] && status="fail"

  jq -nc \
    --arg cluster "$cluster" \
    --arg ring "$ring" \
    --arg status "$status" \
    --argjson passed "$p" \
    --argjson failed "$f" \
    --argjson warnings "$w" \
    --argjson total "$t" \
    --arg csv "$csv_val" \
    --arg catsrc_sha "${catsrc_sha:0:24}" \
    --arg pac_sha "${pac_sha:0:24}" \
    '{cluster:$cluster, ring:$ring, status:$status, checks:{passed:$passed, failed:$failed, warnings:$warnings, total:$total}, csv:$csv, catalog_source_sha:$catsrc_sha, pac_sha:$pac_sha}'
}

emit_json() {
  if [[ ${#JSON_RESULTS[@]} -eq 0 ]]; then
    echo "[]"
    return
  fi
  printf '%s\n' "${JSON_RESULTS[@]}" | jq -s '.'
}

# ── Connectivity Check ──────────────────────────────────────────────────────
# Uses 'oc whoami' instead of 'oc cluster-info' because the latter requires
# permission to list services in kube-system, which non-admin users lack.
check_connectivity() {
  if ! run_oc whoami > /dev/null 2>&1; then
    return 1
  fi
  return 0
}

# Clear per-run state so --watch / --wait iterations don't leak prior results.
# The diagnostic log file persists across iterations; only the per-iteration
# "has entries" flag is reset so print_diag_link only fires when new diags
# are written during the current iteration.
reset_run_state() {
  OBSERVED_CSV=()
  OBSERVED_CATSRC_SHA=()
  OBSERVED_PAC_SHA=()
  SUMMARY_DATA=()
  JSON_RESULTS=()
  DIAG_HAS_ENTRIES=false
}

# Run one full pass over TARGETS. Prints results; returns 0 if all checks passed.
execute_checks() {
  local overall_exit=0
  local cluster_count=${#TARGETS[@]}

  reset_run_state

  if [[ "$ARG_JSON" == true ]]; then
    # ── JSON mode: run detailed checks, collect data, emit JSON on stdout ──
    for target in "${TARGETS[@]}"; do
      local ring="${target%%:*}"
      local cluster="${target##*:}"

      if [[ "$cluster" == "current" ]]; then
        cluster=$(oc config current-context 2>/dev/null || echo "unknown")
        ring="N/A"
      fi

      resolve_cluster_context "$cluster"

      if ! check_connectivity; then
        JSON_RESULTS+=("$(jq -nc \
          --arg cluster "$cluster" --arg ring "$ring" \
          '{cluster:$cluster, ring:$ring, status:"unreachable", checks:{passed:0, failed:0, warnings:0, total:0}}')")
        overall_exit=1
        continue
      fi

      # Detailed check output goes to stderr; stdout is reserved for JSON
      if ! run_checks "$cluster" "$ring" >&2; then
        overall_exit=1
      fi

      local data="${SUMMARY_DATA[${ring}:${cluster}]:-0:0:0:0}"
      JSON_RESULTS+=("$(build_cluster_json "$cluster" "$ring" "$data")")
    done

    emit_json

  elif [[ "$ARG_SUMMARY" == true ]]; then
    # ── Summary table mode ──────────────────────────────────────────────
    header "Pipeline-Service Ring Status Summary"
    printf "  ${DIM}%-6s  %-20s  %-5s  %-5s  %-32s  %-7s  %-5s${RESET}\n" \
      "RING" "CLUSTER" "CATSRC" "TKCFG" "CSV" "PODS" "EVTCTL"
    printf "  ${DIM}%-6s  %-20s  %-5s  %-5s  %-32s  %-7s  %-5s${RESET}\n" \
      "------" "--------------------" "-----" "-----" "--------------------------------" "-------" "-----"

    for target in "${TARGETS[@]}"; do
      local ring="${target%%:*}"
      local cluster="${target##*:}"

      if [[ "$cluster" == "current" ]]; then
        cluster=$(oc config current-context 2>/dev/null || echo "unknown")
        ring="N/A"
      fi

      resolve_cluster_context "$cluster"

      if ! check_connectivity; then
        printf "  %-6s  %-20s  ${RED}%-5s${RESET}  ${RED}%-5s${RESET}  %-32s  %-7s  %-5s\n" \
          "${ring#ring-}" "$cluster" "ERR" "ERR" "unreachable" "—" "—"
        overall_exit=1
        continue
      fi

      run_summary_check "$cluster" "${ring#ring-}"
    done

    if [[ $cluster_count -gt 1 ]]; then
      print_drift_report
    fi

    echo ""
    info "${cluster_count} cluster(s) checked"

  else
    # ── Detailed mode ───────────────────────────────────────────────────
    for target in "${TARGETS[@]}"; do
      local ring="${target%%:*}"
      local cluster="${target##*:}"

      if [[ "$cluster" == "current" ]]; then
        cluster=$(oc config current-context 2>/dev/null || echo "unknown-context")
        ring="N/A"
      fi

      resolve_cluster_context "$cluster"

      header "━━━ ${cluster} (${ring}) ━━━"

      if ! check_connectivity; then
        fail "Cluster unreachable (timeout after ${OC_TIMEOUT}s)"
        overall_exit=1
        echo ""
        continue
      fi

      if ! run_checks "$cluster" "$ring"; then
        overall_exit=1
      fi
    done

    # Final summary + drift report when checking multiple clusters
    if [[ ${#SUMMARY_DATA[@]} -gt 1 ]]; then
      header "━━━ Final Summary ━━━"
      printf "  ${DIM}%-20s  %-8s  %-6s  %-6s  %-6s  %-6s${RESET}\n" \
        "CLUSTER" "RING" "PASS" "FAIL" "WARN" "TOTAL"

      for key in $(echo "${!SUMMARY_DATA[@]}" | tr ' ' '\n' | sort); do
        local ring="${key%%:*}"
        local cluster="${key##*:}"
        local data="${SUMMARY_DATA[$key]}"
        local p f w t
        IFS=: read -r p f w t <<< "$data"

        local status_color="$GREEN"
        [[ $f -gt 0 ]] && status_color="$RED"
        [[ $w -gt 0 && $f -eq 0 ]] && status_color="$YELLOW"

        printf "  ${status_color}%-20s${RESET}  %-8s  ${GREEN}%-6s${RESET}  ${RED}%-6s${RESET}  ${YELLOW}%-6s${RESET}  %-6s\n" \
          "$cluster" "$ring" "$p" "$f" "$w" "$t"
      done

      print_drift_report
      echo ""
    fi
  fi

  if [[ "$ARG_JSON" != true ]]; then
    if [[ $overall_exit -eq 0 ]]; then
      info "${GREEN}All checks passed across ${cluster_count} cluster(s)${RESET}"
    else
      info "${RED}Some checks failed — review output above${RESET}"
      print_diag_link
    fi
  fi

  return $overall_exit
}

# ── PR Overwatch ─────────────────────────────────────────────────────────────
# Two-phase workflow:
#   Phase 1 — poll a GitHub PR every 30s until it reaches MERGED (or CLOSED).
#   Phase 2 — run health checks in --wait mode until all pass.
# Designed to be started once and left running in the background.

PR_POLL_INTERVAL=30  # seconds between GitHub API polls

pr_overwatch() {
  local pr_url="$ARG_PR_URL"

  # ── Validate PR and fetch initial metadata ─────────────────────────────
  local pr_json
  if ! pr_json=$(gh pr view "$pr_url" --json number,title,state,mergedAt,headRefName 2>&1); then
    echo "Error: unable to fetch PR: ${pr_url}" >&2
    echo "$pr_json" >&2
    return 1
  fi

  local pr_number pr_title pr_state pr_branch
  pr_number=$(jq -r '.number' <<< "$pr_json")
  pr_title=$(jq -r '.title' <<< "$pr_json")
  pr_state=$(jq -r '.state' <<< "$pr_json")
  pr_branch=$(jq -r '.headRefName' <<< "$pr_json")

  header "━━━ PR Overwatch: #${pr_number} ━━━"
  info "Title:  ${BOLD}${pr_title}${RESET}"
  info "Branch: ${pr_branch}"
  info "URL:    ${pr_url}"
  info "State:  ${pr_state}"
  echo ""

  # ── Phase 1: Poll until merge ──────────────────────────────────────────
  if [[ "$pr_state" == "MERGED" ]]; then
    local merged_at
    merged_at=$(jq -r '.mergedAt // "unknown"' <<< "$pr_json")
    info "${GREEN}PR already merged at ${merged_at} — skipping to health checks${RESET}"

  elif [[ "$pr_state" == "CLOSED" ]]; then
    fail "PR #${pr_number} is closed without merging — nothing to watch"
    return 1

  else
    info "Polling PR status every ${PR_POLL_INTERVAL}s until merge…"
    info "${DIM}(tip: background with Ctrl-Z + bg, or rerun with nohup … &)${RESET}"
    echo ""

    local attempt=1
    while true; do
      if ! pr_json=$(gh pr view "$pr_url" --json state,mergedAt 2>&1); then
        warn "Unable to reach GitHub API — will retry (${pr_json:0:80})"
        sleep "$PR_POLL_INTERVAL"
        attempt=$((attempt + 1))
        continue
      fi

      pr_state=$(jq -r '.state' <<< "$pr_json")

      if [[ "$pr_state" == "MERGED" ]]; then
        local merged_at
        merged_at=$(jq -r '.mergedAt // "now"' <<< "$pr_json")
        echo ""
        info "${GREEN}PR #${pr_number} merged at ${merged_at}${RESET}"
        break

      elif [[ "$pr_state" == "CLOSED" ]]; then
        echo ""
        fail "PR #${pr_number} was closed without merging"
        return 1
      fi

      # Show CI check summary alongside PR state for situational awareness
      local checks_summary=""
      local checks_json
      if checks_json=$(gh pr checks "$pr_url" --json name,state 2>/dev/null); then
        local total_checks pass_checks fail_checks pend_checks
        total_checks=$(jq 'length' <<< "$checks_json")
        pass_checks=$(jq '[.[] | select(.state == "SUCCESS")] | length' <<< "$checks_json")
        fail_checks=$(jq '[.[] | select(.state == "FAILURE")] | length' <<< "$checks_json")
        pend_checks=$(jq '[.[] | select(.state == "PENDING")] | length' <<< "$checks_json")
        checks_summary="  CI: ${pass_checks}✓ ${fail_checks}✗ ${pend_checks}⧖ / ${total_checks}"
      fi

      printf "${DIM}── pr-check %d (%s) — %s%s ──${RESET}\n" \
        "$attempt" "$(date -Iseconds 2>/dev/null || date)" "$pr_state" "$checks_summary"

      sleep "$PR_POLL_INTERVAL"
      attempt=$((attempt + 1))
    done
  fi

  # ── Phase 2: Post-merge health verification ────────────────────────────
  echo ""
  header "━━━ Post-Merge Health Verification: #${pr_number} ━━━"
  info "Running health checks until all pass (interval=${ARG_INTERVAL}s${ARG_TIMEOUT:+, timeout=${ARG_TIMEOUT}s})"
  echo ""

  init_diag_log

  local start=$SECONDS
  local attempt=1
  while true; do
    printf "${DIM}── post-merge check %d (%s) ──${RESET}\n" \
      "$attempt" "$(date -Iseconds 2>/dev/null || date)"

    if execute_checks; then
      echo ""
      info "${GREEN}${BOLD}✓ PR #${pr_number} merged and all health checks passed${RESET}"
      print_diag_link
      return 0
    fi

    if [[ "$ARG_TIMEOUT" -gt 0 && $((SECONDS - start)) -ge "$ARG_TIMEOUT" ]]; then
      echo ""
      print_diag_link
      fail "Timed out after ${ARG_TIMEOUT}s waiting for post-merge health checks"
      return 1
    fi

    info "Retrying health checks in ${ARG_INTERVAL}s…"
    sleep "$ARG_INTERVAL"
    attempt=$((attempt + 1))
    echo ""
  done
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  parse_args "$@"
  resolve_rings_file

  # Dependency check
  local required_cmds=(oc yq)
  [[ "$ARG_JSON" == true ]] && required_cmds+=(jq)
  if [[ -n "$ARG_PR_URL" ]]; then
    required_cmds+=(gh jq)
  fi
  for cmd in "${required_cmds[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
      echo "Error: '$cmd' is required but not found in PATH" >&2
      exit 1
    fi
  done

  resolve_targets
  init_diag_log

  if [[ -n "$ARG_PR_URL" ]]; then
    pr_overwatch
    return $?
  fi

  if [[ "$ARG_WATCH" == true ]]; then
    info "Watching every ${ARG_INTERVAL}s — Ctrl-C to stop"
    while true; do
      clear 2>/dev/null || printf '\033[2J\033[H'
      printf "${DIM}%s${RESET}\n" "$(date -Iseconds 2>/dev/null || date)"
      execute_checks || true
      sleep "$ARG_INTERVAL"
    done
  fi

  if [[ "$ARG_WAIT" == true ]]; then
    local start=$SECONDS
    local attempt=1
    info "Waiting for checks to pass (interval=${ARG_INTERVAL}s${ARG_TIMEOUT:+, timeout=${ARG_TIMEOUT}s})"
    while true; do
      printf "${DIM}── attempt %d (%s) ──${RESET}\n" "$attempt" "$(date -Iseconds 2>/dev/null || date)"
      if execute_checks; then
        info "${GREEN}Checks passed — done waiting${RESET}"
        return 0
      fi

      if [[ "$ARG_TIMEOUT" -gt 0 && $((SECONDS - start)) -ge "$ARG_TIMEOUT" ]]; then
        print_diag_link
        echo "Error: timed out after ${ARG_TIMEOUT}s waiting for checks to pass" >&2
        return 1
      fi

      info "Retrying in ${ARG_INTERVAL}s…"
      sleep "$ARG_INTERVAL"
      attempt=$((attempt + 1))
      echo ""
    done
  fi

  execute_checks
}

main "$@"
