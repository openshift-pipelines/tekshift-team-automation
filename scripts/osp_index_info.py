#!/usr/bin/env python3

import re
import json
import subprocess
import sys
import typing as t
import tempfile

IMAGE_REPO_TO_GIT_REPO = {
	"pipelines-cache-rhel9": "openshift-pipelines/tekton-caches",
	"pipelines-chains-controller-rhel9": "tektoncd/chains",
	"pipelines-cli-tkn-rhel9": "tektoncd/cli",
	"pipelines-console-plugin-rhel9": "openshift-pipelines/console-plugin",
	"pipelines-controller-rhel9": "tektoncd/pipeline",
	"pipelines-entrypoint-rhel9": "tektoncd/pipeline",
	"pipelines-events-rhel9": "tektoncd/pipeline",
	"pipelines-git-init-rhel9": "openshift-pipelines/ecosystem-images",
	"pipelines-hub-api-rhel9": "tektoncd/hub",
	"pipelines-hub-db-migration-rhel9": "tektoncd/hub",
	"pipelines-hub-ui-rhel9": "tektoncd/hub",
	"pipelines-manual-approval-gate-controller-rhel9": "openshift-pipelines/manual-approval-gate",
	"pipelines-manual-approval-gate-webhook-rhel9": "openshift-pipelines/manual-approval-gate",
	"pipelines-nop-rhel9": "tektoncd/pipeline",
	"pipelines-opc-rhel9": "",
	"pipelines-operator-bundle": "tektoncd/operator",
	"pipelines-operator-proxy-rhel9": "tektoncd/operator",
	"pipelines-operator-webhook-rhel9": "tektoncd/operator",
	"pipelines-pipelines-as-code-cli-rhel9": "openshift-pipelines/pipelines-as-code",
	"pipelines-pipelines-as-code-controller-rhel9": "openshift-pipelines/pipelines-as-code",
	"pipelines-pipelines-as-code-watcher-rhel9": "openshift-pipelines/pipelines-as-code",
	"pipelines-pipelines-as-code-webhook-rhel9": "openshift-pipelines/pipelines-as-code",
	"pipelines-pruner-controller-rhel9": "openshift-pipelines/tektoncd-pruner",
	"pipelines-resolvers-rhel9": "tektoncd/pipeline",
	"pipelines-results-api-rhel9": "tektoncd/results",
	"pipelines-results-retention-policy-agent-rhel9": "tektoncd/results",
	"pipelines-results-watcher-rhel9": "tektoncd/results",
	"pipelines-rhel9-operator": "openshift-pipelines/operator",
	"pipelines-sidecarlogresults-rhel9": "tektoncd/pipeline",
	"pipelines-triggers-controller-rhel9": "tektoncd/triggers",
	"pipelines-triggers-core-interceptors-rhel9": "tektoncd/triggers",
	"pipelines-triggers-eventlistenersink-rhel9": "tektoncd/triggers",
	"pipelines-triggers-webhook-rhel9": "tektoncd/triggers",
	"pipelines-webhook-rhel9": "tektoncd/pipeline",
	"pipelines-workingdirinit-rhel9": "tektoncd/pipeline",
}

def stderr(msg: str):
    print(msg, file=os.stderr)

class Image:
    image_ref: str
    image_repo: str
    image_digest: str
    code_repo: str | None = None
    _downstream_commit: str | None = None
    _upstream_commit: str | None = None
    _container_id: str | None = None

    def __init__(self, image_ref: str):
        self.image_ref = image_ref
        image_repo_full = image_ref.split("@")[0]
        self.image_repo = image_repo_full.split("/")[-1]
        self.image_digest = image_ref.split(":")[1]
        self.code_repo = IMAGE_REPO_TO_GIT_REPO.get(self.image_repo)

    def is_pipelines_maintained(self) -> bool:
        return self.image_repo in IMAGE_REPO_TO_GIT_REPO.keys()

    def _get_container_id(self):
        if self._container_id is not None:
            return self._container_id
        cmd = subprocess.run(["podman", "create", "-q", self.image_ref], capture_output=True, text=True, check=True)
        self._container_id = str(cmd.stdout).strip()
        return self._container_id

    def downstream_commit(self) -> str | None:
        if self._downstream_commit is not None:
            return self._downstream_commit

        try:
            cmd = subprocess.run(["podman", "inspect", self._get_container_id()], capture_output=True, text=True, check=True)
            inspected_containers = json.loads(cmd.stdout)
            if len(inspected_containers) != 1:
                self._downstream_commit = ""
            else:
                self._downstream_commit = inspected_containers[0].get("Config", {}).get("Labels", {}).get("vcs-ref", "")
        except subprocess.CalledProcessError:
            self._downstream_commit = ""

        return self._downstream_commit

    def upstream_commit(self) -> str | None:
        if self._upstream_commit is not None:
            return self._upstream_commit

        try:
            with tempfile.TemporaryDirectory() as tmpdir:
                outfile = f"{tmpdir}/{self.image_repo}_head"
                subprocess.run(["podman", "cp", f"{self._get_container_id()}:/kodata/HEAD", outfile], capture_output=True, check=True)
                with open(outfile) as head:
                    self._upstream_commit = str(head.read()).strip()
        except subprocess.CalledProcessError:
            self._downstream_commit = ""

        return self._upstream_commit

    def as_dict(self) -> dict:
        d = {"image": self.image_ref}
        if self.downstream_commit():
            d["downstream_commit"] = self.downstream_commit()
        if self.upstream_commit():
            d["upstream_commit"] = self.upstream_commit()
            if self.code_repo:
                d["git_link"] = f"github.com/{self.code_repo}/commit/{self.upstream_commit()}"
        return d

    def clean(self):
        if self._container_id is not None:
            subprocess.run(["podman", "container", "rm", self._container_id], capture_output=True, text=True, check=True)


class Bundle:
    data: dict[str, t.Any]
    images: list[Image]
    name: str

    def __init__(self, bundle_data: dict[str, t.Any]):
        self.data = bundle_data
        self.name = self.data.get("name")
        self.images = [Image(i.get("image")) for i in self.data.get("relatedImages", []) if i.get("image") and i.get("name")]

    def version(self) -> str:
        properties = self.data.get("properties", [])
        package_properties = [p for p in properties if p.get("type") == "olm.package" and p.get("value", {}).get("packageName") == "openshift-pipelines-operator-rh"]
        if len(package_properties) != 1:
            return ""
        return package_properties[0].get("value", {}).get("version", "")

    def as_dict(self) -> dict[str, dict[t.Any, t.Any]]:
        return {
            "version": self.version(),
            "images": {i.image_repo: i.as_dict() for i in self.images},
        }

    def clean(self):
        for image in self.images:
            image.clean()

class Catalog:
    def __init__(self, image: str):
        self._bundles: list[Bundle] = []
        self.container_id: None | str = None
        self.image = image
        self.entries = self._pull_data()

    def _pull_data(self) -> list:
        try:
            container_id = subprocess.run(["podman", "create", "-q", self.image], capture_output=True, text=True, check=True).stdout
        except subprocess.CalledProcessError as e:
            raise RuntimeError(f"error creating container for catalog '{self.image}':\n---\n{e.output}\n---\n{e.stderr}") from e

        with tempfile.TemporaryDirectory() as tmpdir:
            outfile = f"{tmpdir}/catalog.json"
            subprocess.run(["podman", "cp", f"{str(container_id.strip())}:/configs/openshift-pipelines-operator-rh/catalog.json", outfile], check=True)
            with open(outfile) as catalog:
                catalog_json = catalog.read()
                objects = re.findall(r'\n(\{.*?\n\})', catalog_json, re.DOTALL)
                try:
                    return [json.loads(o) for o in objects]
                except Exception as e:
                    for o in objects:
                        try:
                            json.loads(o)
                        except:
                            stderr(o)
                            raise e

    def release_channels(self) -> dict[str, list[dict[str, t.Any]]]:
        return {e.get("name"): e.get("entries") for e in self.entries if e.get("schema") == "olm.channel"}

    def bundles(self) -> list[Bundle]:
        if not self._bundles:
            self._bundles = [Bundle(e) for e in self.entries if e.get("schema") == "olm.bundle"]
        return self._bundles

    def clean(self):
        if self.container_id is not None:
            subprocess.run(["podman", "container", "rm", self.container_id], text=True, check=True)
        for entry in self.bundles():
            entry.clean()


def __main__():
    catalog = None
    try:
        if len(sys.argv) == 1:
            stderr("No index image provided")

        catalog_image = sys.argv[1]
        catalog = Catalog(catalog_image)
        bundles = catalog.bundles()
        if nightly_bundle := list(b.as_dict() for b in bundles if b.name.startswith("openshift-pipelines-operator-rh.v5.0.5")):
            print(json.dumps(nightly_bundle[0]))
    finally:
        if catalog != None:
            catalog.clean()

if __name__ == "__main__":
    __main__()
