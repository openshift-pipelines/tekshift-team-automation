#!/usr/bin/env python3

import logging
import argparse
import re
import json
import subprocess
import os
import sys
import typing as t
import tempfile
from functools import cache, cached_property
from urllib.request import urlopen
from urllib.error import HTTPError

# TODO: This should be coming from the upstream-vcs-location label, if present
IMAGE_REPO_TO_GIT_REPO = {
    "pipelines-cache-rhel9": "openshift-pipelines/tekton-caches",
    "pipelines-chains-controller-rhel9": "tektoncd/chains",
    "pipelines-cli-tkn-rhel9": "tektoncd/cli",
    "pipelines-console-plugin-rhel9": "openshift-pipelines/console-plugin",
    "pipelines-controller-rhel9": "tektoncd/pipeline",
    "pipelines-entrypoint-rhel9": "tektoncd/pipeline",
    "pipelines-events-rhel9": "tektoncd/pipeline",
    "pipelines-git-init-rhel9": "openshift-pipelines/tektoncd-git-clone",
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
    "pipelines-pruner-controller-rhel9": "tektoncd/pruner",
    "pipelines-resolvers-rhel9": "tektoncd/pipeline",
    "pipelines-results-api-rhel9": "tektoncd/results",
    "pipelines-results-retention-policy-agent-rhel9": "tektoncd/results",
    "pipelines-results-watcher-rhel9": "tektoncd/results",
    "pipelines-rhel9-operator": "tektoncd/operator",
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


logger = logging.getLogger(os.path.basename(sys.argv[0]))

pulled_images = []
created_images = []


class Image:
    image_ref: str
    image_repo: str
    image_digest: str
    code_repo: str | None = None
    _container_id: str | None = None

    def __init__(self, image_ref: str):
        # TODO: add better handling for tags, tag+digest, and invalid image formats
        self.image_ref = image_ref
        image_repo_full = image_ref.split("@")[0]
        self.image_repo = image_repo_full.split("/")[-1]

        colon_parts = image_ref.split(":")
        if len(colon_parts) > 1:
            self.image_digest = colon_parts[1]
        else:
            self.image_digest = None

        self.code_repo = IMAGE_REPO_TO_GIT_REPO.get(self.image_repo)

    def is_pipelines_maintained(self) -> bool:
        return self.image_repo in IMAGE_REPO_TO_GIT_REPO.keys()

    def _pull(self):
        if self.image_ref in pulled_images:
            logger.warning(f"image {self.image_ref} pulled more than once")
        try:
            logger.debug(f"pulling image {self.image_ref}")
            subprocess.run(["podman", "exists", self.image_ref], capture_output=True, text=True, check=True)
        except subprocess.CalledProcessError:
            subprocess.run(["podman", "pull", "-q", self.image_ref], capture_output=True, text=True, check=True)

    @cache
    def _labels(self) -> dict[str, str]:
        try:
            self._pull()
            cmd = subprocess.run(["podman", "inspect", self.image_ref], capture_output=True, text=True, check=True)
            inspected_containers = json.loads(cmd.stdout)
            if len(inspected_containers) != 1:
                return {}
            return inspected_containers[0].get("Config", {}).get("Labels", {})
        except subprocess.CalledProcessError:
            logger.exception(f"error inspecting image {self.image_ref}")
            return {}

    @cache
    def _get_container_id(self):
        if self.image_ref in created_images:
            logger.warning(f"image {self.image_ref} created more than once")
        logger.debug(f"creating container for image {self.image_ref}")
        cmd = subprocess.run(["podman", "create", "-q", self.image_ref], capture_output=True, text=True, check=True)
        self._container_id = str(cmd.stdout).strip()
        return self._container_id

    @cache
    def downstream_commit(self) -> str | None:
        return self._labels().get("vcs-ref")

    @cache
    def upstream_commit(self) -> str | None:
        logger.debug(f"fetching upstream commit for {self.image_ref}")
        if upstream_commit := self._labels().get("upstream-vcs-ref"):
            return upstream_commit
        try:
            with tempfile.TemporaryDirectory() as tmpdir:
                outfile = f"{tmpdir}/{self.image_repo}_head"
                subprocess.run(["podman", "cp", f"{self._get_container_id()}:/kodata/HEAD", outfile], capture_output=True, check=True, text=True)
                with open(outfile) as head:
                    return str(head.read()).strip()
        except subprocess.CalledProcessError as err:
            logger.debug(f"error extracting head file for {self.image_repo}: {err.stderr.strip()}")
            return None

    def as_dict(self, show_info: bool) -> dict:
        d = {"image": self.image_ref}
        if show_info:
            if self.downstream_commit():
                d["downstream_commit"] = self.downstream_commit()
            if self.upstream_commit():
                d["upstream_commit"] = self.upstream_commit()
                if self.code_repo:
                    d["git_link"] = f"github.com/{self.code_repo}/commit/{self.upstream_commit()}"
        return d

    @property
    def git_link(self) -> str | None:
        if self.code_repo and self.upstream_commit():
            return f"github.com/{self.code_repo}/commit/{self.upstream_commit()}"

    @cache
    def exists(self) -> bool:
        try:
            self._pull()
        except subprocess.CalledProcessError:
            return False
        return True

    def clean(self):
        if self._container_id is not None:
            subprocess.run(["podman", "container", "rm", self._container_id], capture_output=True, text=True, check=True)


class Bundle:
    data: dict[str, t.Any]
    name: str

    def __init__(self, bundle_data: dict[str, t.Any]):
        self.data = bundle_data
        self.name = self.data.get("name")

    @cached_property
    def images(self) -> list[Image]:
        image_list = [i.get("image") for i in self.data.get("relatedImages", []) if i.get("image") and i.get("name")]
        return [Image(i) for i in set(image_list)]

    def version(self) -> str:
        properties = self.data.get("properties", [])
        package_properties = [p for p in properties if p.get("type") == "olm.package" and p.get("value", {}).get("packageName") == "openshift-pipelines-operator-rh"]
        if len(package_properties) != 1:
            return "No version found"
        return package_properties[0].get("value", {}).get("version", "")

    def as_dict(self, show_info: bool = False) -> dict[str, dict[t.Any, t.Any]]:
        return {
            "version": self.version(),
            "images": {i.image_repo: i.as_dict(show_info=show_info) for i in self.images},
        }

    def clean(self):
        for image in self.images:
            image.clean()

    def validate_images(self) -> str:
        if invalid_images := [image for image in self.images if not image.exists()]:
            return "Missing images:\n\t" + "\n\t".join(i.image_ref for i in invalid_images)
        return "All images reachable"


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

        self.container_id = str(container_id.strip())

        with tempfile.TemporaryDirectory() as tmpdir:
            outfile = f"{tmpdir}/catalog.json"
            subprocess.run(["podman", "cp", f"{self.container_id}:/configs/openshift-pipelines-operator-rh/catalog.json", outfile], check=True)
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
            subprocess.run(["podman", "container", "rm", self.container_id], capture_output=True, text=True, check=True)
        for entry in self.bundles():
            entry.clean()

    def get_bundle(self, name: str) -> Bundle:
        bundle_names = [b.name for b in self.bundles()]
        matching_bundles = list(b for b in self.bundles() if b.name.startswith(name))
        if len(matching_bundles) == 0:
            raise Exception(f"No bundle found with name {name}. Bundles: {bundle_names}")
        if len(matching_bundles) > 1:
            raise Exception("Cannot select Bundle from ambiguous name {name}. Found {len(matching_bundles} matches")
        return matching_bundles[0]


class RepoChange:
    image_name: str
    git_repo: str
    old_revision: str
    new_revision: str

    def __init__(self, image_name: str, git_repo: str, old_revision: str, new_revision: str):
        self.image_name = image_name
        self.git_repo = git_repo
        self.old_revision = old_revision
        self.new_revision = new_revision

    def from_images(old_image: Image, new_image: Image) -> t.Self | None:
        return RepoChange(new_image.image_repo, new_image.code_repo, old_image.upstream_commit(), new_image.upstream_commit())

    def compare_url(self) -> str:
        return f"https://api.github.com/repos/{self.git_repo}/compare/{self.old_revision}...{self.new_revision}"

    def warnings(self) -> list[str]:
        warnings = []

        if self.git_repo and self.old_revision and self.new_revision:
            def commit_date(sha: str) -> str:
                url = f"https://api.github.com/repos/{self.git_repo}/commits/{sha}"
                logger.debug(f"Fetching commit data from {url}")
                try:
                    with urlopen(url) as r:
                        resp = json.load(r)
                        return resp.get("commit", {}).get("committer", {}).get("date", "")
                except HTTPError:
                    warnings.append(f"unable to find revision {sha[:8]} in repo {self.git_repo}")
                return ""

            old_date = commit_date(self.old_revision)
            new_date = commit_date(self.new_revision)
            if old_date and new_date and new_date <= old_date and self.old_revision != self.new_revision:
                warnings.append(f"new revision {self.new_revision[:8]} ({new_date}) created before old revision {self.old_revision[:8]} ({old_date})")
        elif self.git_repo:
            missing_revision = "old"
            if self.old_revision:
                missing_revision = "new"
            warnings.append(f"no {missing_revision} revision to compare")
        return warnings

    @cache
    def _comparison(self) -> dict[str, object]:
        with urlopen(self.compare_url()) as r:
            return json.load(r)

    def commits(self) -> dict[str, object]:
        return self._comparison().get("commits", [])


def get_changes(old_bundle: Bundle, new_bundle: Bundle) -> list[RepoChange]:
    images_by_image_repo: dict[str, Image] = {}

    # Since the bundles aren't guaranteed to have the same set of images or image order, we can't simply zip the two lists
    for img in new_bundle.images:
        images_by_image_repo[img.image_repo] = [img]

    for img in old_bundle.images:
        if images_by_image_repo.get(img.image_repo):
            images_by_image_repo[img.image_repo] += [img]

    changes: dict[str, RepoChange] = {}

    for repo, imgs in images_by_image_repo.items():
        if len(imgs) != 2:
            logger.warning(f"Skipping image {repo} - missing image to compare")
            continue

        new_image: Image = imgs[0]
        old_image: Image = imgs[1]

        key = new_image.code_repo

        if key in changes and changes[key].old_revision is not None and changes[key].new_revision is not None:
            continue

        if None in [old_image.git_link, new_image.git_link, old_image.upstream_commit(), new_image.upstream_commit()]:
            logger.warning(f"Skipping image {repo} - no upstream info")
            continue

        changes[key] = RepoChange.from_images(old_image, new_image)

    return changes.values()


def compare(args):
    bundle_name = f"openshift-pipelines-operator-rh.{args.channel}"
    old_catalog = Catalog(args.old_image)
    new_catalog = Catalog(args.new_image)

    # TODO: these may need to be different channels in the future
    old_bundle = old_catalog.get_bundle(bundle_name)
    new_bundle: Bundle = new_catalog.get_bundle(bundle_name)

    output = {
        "old_catalog": old_catalog.image,
        "new_catalog": new_catalog.image,
        "channel": args.channel,
        "changes": {}
    }
    for change in get_changes(old_bundle, new_bundle):
        data = None
        match args.action:
            case "show-heads":
                data = {"old_sha": change.old_revision, "new_sha": change.new_revision}
            case "show-compare-urls":
                data = {"change_url": change.compare_url()}
            case "show-all-shas":
                try:
                    data = {"commits": [commit.get("sha") for commit in change.commits() if commit.get("sha")]}
                except Exception as e:
                    logger.exception(f"Could not get SHAs for image {change.image_name}: {e}")
            case "show-all-commits":
                data = {}
                try:
                    data = {"commits": [{"sha": commit.get("sha"), "message": commit.get('commit', {}).get("message")} for commit in change.commits()]}
                except Exception as e:
                    logger.exception(f"Could not get SHAs for image {change.image_name}: {e}")
        data["image"] = change.image_name
        if warnings := change.warnings():
            data["warning"] = warnings

        output["changes"][change.git_repo] = data

    format = args.output

    if format == "text":
        print(f"Comparing {output['old_catalog']} to {output['new_catalog']} for {output['channel']}\n---")

        for repo, change in output["changes"].items():
            print(f"{repo}:")
            match args.action:
                case "show-heads":
                    print(f"\told commit: {change['old_sha']}\n\tnew commit: {change['new_sha']}")
                case "show-compare-urls":
                    print("\t", change['change_url'])
                case "show-all-shas":
                    try:
                        for sha in change['commits']:
                            print("\t" + sha)
                    except Exception as e:
                        logger.exception(f"Could not get SHAs for image {change['image']}: {e}")
                case "show-all-commits":
                    try:
                        for commit in change['commits']:
                            message = commit['message'].replace("\n", "\n\t\t")
                            print(f"\n\t{commit.get('sha')}\n\t\t {message}")
                    except Exception as e:
                        logger.exception(f"Could not get SHAs for image {change['image']}: {e}")
            if warnings := change.get("warning"):
                print("\tWarnings:")
                for w in warnings:
                    print("\t\t" + w)
    elif format == "json":
        print(json.dumps(output, indent=" "))


def __main__():
    parser = argparse.ArgumentParser("Openshift Pipelines Index inspector")
    parser.add_argument("-v", "--verbose", action='store_true')

    parser.set_defaults(func=None)
    subparses = parser.add_subparsers()

    for (cmd, help) in [
        ("build-version", "output the index build version and exit"),
        ("full-info", "output image, upstream and downstream source information, and link to upstream source in JSON format"),
        ("list-images", "output list of all images included in the index, by component"),
        ("validate-images","validate that all images linked in the index exist"),
    ]:
        subparser = subparses.add_parser(cmd, help=help)
        subparser.set_defaults(command=cmd)
        subparser.add_argument("image")
        subparser.add_argument("-c", "--channel", default="v5.0.5")

    compare_parser = subparses.add_parser("compare", help="compare two index images")
    compare_parser.add_argument("old_image", type=str)
    compare_parser.add_argument("new_image", type=str)
    compare_parser.add_argument("action", default="show-heads", choices=["show-heads", "show-compare-urls", "show-all-shas", "show-all-commits"])
    compare_parser.set_defaults(func=compare)
    compare_parser.add_argument("-c", "--channel", default="v5.0.5")
    compare_parser.add_argument("-o", "--output", default="text", choices=["json", "text"])

    args = parser.parse_args()

    if args.verbose:
        logging.basicConfig(level=logging.DEBUG)
        logger.info("Log level set to debug")

    if args.func is not None:
        args.func(args)
    else:
        catalog = None
        try:
            catalog = Catalog(args.image)
            bundle = catalog.get_bundle(f"openshift-pipelines-operator-rh.{args.channel}")

            if args.command == "full-info":
                print(json.dumps(bundle.as_dict(show_info=True)))
            elif args.command == "list-images":
                print(json.dumps(bundle.as_dict(show_info=False)))
            elif args.command == "build-version":
                print(f"Name: {bundle.name}\nVersion: {bundle.version()}")
            elif args.command == "validate-images":
                print(bundle.validate_images())
            else:
                print("Unknown command \"{args.command}\"")
                print(parser.format_help())
        finally:
            if catalog is not None:
                catalog.clean()


if __name__ == "__main__":
    __main__()
