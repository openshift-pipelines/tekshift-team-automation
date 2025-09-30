#!/usr/bin/env bash
# Dependencies:
#   - podman
#   - jq
#   - fzf

set -euo pipefail

declare -A repositories
repositories=(
	["pipelines-cache-rhel9"]="openshift-pipelines/tekton-caches"
	["pipelines-chains-controller-rhel9"]="tektoncd/chains"
	["pipelines-cli-tkn-rhel9"]="tektoncd/cli"
	["pipelines-console-plugin-rhel9"]="openshift-pipelines/console-plugin"
	["pipelines-controller-rhel9"]="tektoncd/pipeline"
	["pipelines-entrypoint-rhel9"]="tektoncd/pipeline"
	["pipelines-events-rhel9"]="tektoncd/pipeline"
	["pipelines-git-init-rhel9"]="openshift-pipelines/ecosystem-images"
	["pipelines-hub-api-rhel9"]="tektoncd/hub"
	["pipelines-hub-db-migration-rhel9"]="tektoncd/hub"
	["pipelines-hub-ui-rhel9"]="tektoncd/hub"
	["pipelines-manual-approval-gate-controller-rhel9"]="openshift-pipelines/manual-approval-gate"
	["pipelines-manual-approval-gate-webhook-rhel9"]="openshift-pipelines/manual-approval-gate"
	["pipelines-nop-rhel9"]="tektoncd/pipeline"
	["pipelines-opc-rhel9"]=""
	["pipelines-operator-bundle"]="tektoncd/operator"
	["pipelines-operator-proxy-rhel9"]="tektoncd/operator"
	["pipelines-operator-webhook-rhel9"]="tektoncd/operator"
	["pipelines-pipelines-as-code-cli-rhel9"]="openshift-pipelines/pipelines-as-code"
	["pipelines-pipelines-as-code-controller-rhel9"]="openshift-pipelines/pipelines-as-code"
	["pipelines-pipelines-as-code-watcher-rhel9"]="openshift-pipelines/pipelines-as-code"
	["pipelines-pipelines-as-code-webhook-rhel9"]="openshift-pipelines/pipelines-as-code"
	["pipelines-pruner-controller-rhel9"]="openshift-pipelines/tektoncd-pruner"
	["pipelines-resolvers-rhel9"]="tektoncd/pipeline"
	["pipelines-results-api-rhel9"]="tektoncd/results"
	["pipelines-results-retention-policy-agent-rhel9"]="tektoncd/results"
	["pipelines-results-watcher-rhel9"]="tektoncd/results"
	["pipelines-rhel9-operator"]="openshift-pipelines/operator"
	["pipelines-sidecarlogresults-rhel9"]="tektoncd/pipeline"
	["pipelines-triggers-controller-rhel9"]="tektoncd/triggers"
	["pipelines-triggers-core-interceptors-rhel9"]="tektoncd/triggers"
	["pipelines-triggers-eventlistenersink-rhel9"]="tektoncd/triggers"
	["pipelines-triggers-webhook-rhel9"]="tektoncd/triggers"
	["pipelines-webhook-rhel9"]="tektoncd/pipeline"
	["pipelines-workingdirinit-rhel9"]="tektoncd/pipeline"
)

function parse_component_image() {
    IMAGE="${1:?No component image provided}"
	IMAGE_REF=$(echo "${IMAGE}" | rev | cut -d '/' -f 1 | rev)
	IMAGE_REPO=$(echo "${IMAGE_REF}" | cut -d '@' -f 1)
	DOWNSTREAM_COMMIT=""
	UPSTREAM_COMMIT=""

	OUT="- ${IMAGE_REF}:"

	if [[ "${IMAGE}" == quay.io/openshift-pipeline/* ]]; then
    	CONTAINER=$(podman create -q "${IMAGE}")
    	DOWNSTREAM_COMMIT=$(podman inspect "${CONTAINER}" | jq -r '.[0].Config.Labels."vcs-ref"')
    	[[ "${DOWNSTREAM_COMMIT}" == "" ]] || OUT="${OUT}\n    downstream_commit: ${DOWNSTREAM_COMMIT}"

    	podman cp "${CONTAINER}:/kodata/HEAD" "${CONTAINER}_head" 2>/dev/null && UPSTREAM_COMMIT=$(cat "${CONTAINER}_head") || echo -n ""
		if [[ -n "${UPSTREAM_COMMIT}" && -n "${repositories[${IMAGE_REPO}]}" ]]; then
    		REPO=${repositories["${IMAGE_REPO}"]}
    		UPSTREAM_COMMIT="https://github.com/${REPO}/commit/${UPSTREAM_COMMIT}"
		fi
    	[[ "${UPSTREAM_COMMIT}" == "" ]] || OUT="${OUT}\n    upstream_commit: ${UPSTREAM_COMMIT}"
	fi

	if [[ "${OUT}" == *: ]]; then
    	OUT="${OUT} {}"
	fi

	echo -e "${OUT}"
}


IMAGE="${1:?No image provided}"

TMPDIR=$(mktemp -d)
cd "${TMPDIR}"

echo "Pulling index image ${IMAGE}"
INDEX_CONTAINER=$(podman create "${IMAGE}")

INDEX_CATALOG_PATH="/configs/openshift-pipelines-operator-rh/catalog.json"
CATALOG_FILE="catalog.json"
podman cp "${INDEX_CONTAINER}:${INDEX_CATALOG_PATH}" "${CATALOG_FILE}"

RELEASE_CHANNEL=$(jq -r 'select(.schema == "olm.channel").name' "${CATALOG_FILE}" | fzf --prompt "Release Channel> ")
NUM_ENTRIES=$(jq -r "select(.schema == \"olm.channel\" and .name == \"${RELEASE_CHANNEL}\").entries | length" "${CATALOG_FILE}")
if [[ "${NUM_ENTRIES}" == "1" ]]; then
    BUNDLE=$(jq -r "select(.schema == \"olm.channel\" and .name == \"${RELEASE_CHANNEL}\").entries[0].name" "${CATALOG_FILE}")
    echo "Only available version"
else
    BUNDLE=$(jq -r "select(.schema == \"olm.channel\" and .name == \"${RELEASE_CHANNEL}\").entries[].name" "${CATALOG_FILE}" | fzf --prompt "Release version> ")
fi
jq "select(.schema == \"olm.bundle\" and .name == \"${BUNDLE}\")" "${CATALOG_FILE}" > bundle.json
VERSION=$(jq -r ".properties[] | select(.type == \"olm.package\" and .value.packageName == \"openshift-pipelines-operator-rh\").value.version" bundle.json)
echo "Using version ${VERSION}"

echo "---"
for image in $(jq -r '.relatedImages[].image' bundle.json | sort | uniq); do
    parse_component_image "${image}" || echo "Cannot get image info for ${image}" >&2
done
