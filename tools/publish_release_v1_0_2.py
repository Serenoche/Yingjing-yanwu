"""One-release publisher. Fixed repository, source, assets and official API only."""
from __future__ import annotations

import base64
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

REPOSITORY = "Serenoche/Yingjing-yanwu"
BRANCH = "refs/heads/release/publish-v1.0.2"
SOURCE = "7b5d2cbb2a3beb824f92af35c8506fa4bb4cb6ab"
TAG = "v1.0.2"
TITLE = "影境演武 v1.0.2（预发布）"
PREFIX = "/repos/" + REPOSITORY
SPECS = {
    "yingjing-yanwu-v1.0.2-windows-x64.zip": (21822827, "43e7a29a9de27f7c99045fd21689cdadb29e3d388c65e8bf5882a1dd13759f34", "application/zip", None),
    "ReleaseNotes-v1.0.2.md": (4329, "f4df35b4d921cf0e3fa8cf5fce35655f6acd92f3710ebab8a63f821c3b6db5a6", "text/markdown", "docs/releases/v1.0.2.md"),
    "SHA256SUMS.txt": (195, "e6b30425f408e8523e51254fa5624de7850fa2caa137c9d0ff4507ae37903f51", "text/plain", "docs/releases/v1.0.2-SHA256SUMS.txt"),
}


class PublicationError(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise PublicationError(message)


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def git_blob_sha(raw):
    return hashlib.sha1(f"blob {len(raw)}\0".encode("ascii") + raw).hexdigest()


def pinned_text(raw, size, expected_sha):
    # Checkout may apply .gitattributes eol=lf. Recover only an exact approved
    # byte representation; uploaded bytes still match the original asset hash.
    lf = raw.replace(b"\r\n", b"\n")
    for candidate in (raw, lf, lf.replace(b"\n", b"\r\n")):
        if len(candidate) == size and digest(candidate) == expected_sha:
            return candidate
    raise PublicationError("Local asset content differs")


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "Duplicate JSON key")
        result[key] = value
    return result


@dataclass(frozen=True)
class Asset:
    name: str
    size: int
    sha256: str
    content_type: str
    chunks: tuple = ()
    local: bytes | None = None


@dataclass(frozen=True)
class Plan:
    assets: tuple[Asset, ...]
    body: str


def load_plan(root):
    raw = (root / "docs/releases/v1.0.2-assets.json").read_bytes()
    manifest = json.loads(raw.decode("utf-8"), object_pairs_hook=unique_object)
    require(set(manifest) == {"schemaVersion", "repository", "tag", "sourceCommit", "assets"}, "Unexpected manifest fields")
    require(type(manifest["schemaVersion"]) is int and manifest["schemaVersion"] == 1 and manifest["repository"] == REPOSITORY
            and manifest["tag"] == TAG and manifest["sourceCommit"] == SOURCE, "Manifest identity differs")
    require(isinstance(manifest["assets"], list) and len(manifest["assets"]) == 3, "Exactly three assets are required")
    assets, names = [], set()
    for entry in manifest["assets"]:
        name = entry.get("name")
        require(name in SPECS and name not in names, "Unexpected or duplicate asset name")
        names.add(name)
        size, sha, media, local_path = SPECS[name]
        require(type(entry.get("bytes")) is int and entry["bytes"] == size and entry.get("sha256") == sha, "Asset pin differs")
        allowed_media = {media, media + "; charset=utf-8"}
        if name == "ReleaseNotes-v1.0.2.md":
            allowed_media.update({"text/plain", "text/plain; charset=utf-8"})
        require(entry.get("contentType") in allowed_media, "Asset media type differs")
        common = {"name", "contentType", "bytes", "sha256"}
        if local_path:
            require(set(entry) == common | {"localPath"} and entry["localPath"] == local_path, "Local asset path differs")
            content = pinned_text((root / local_path).read_bytes(), size, sha)
            assets.append(Asset(name, size, sha, entry["contentType"], local=content))
        else:
            require(set(entry) == common | {"chunks"}, "ZIP asset fields differ")
            chunks = entry["chunks"]
            require(isinstance(chunks, list) and 1 <= len(chunks) <= 64, "Invalid ZIP chunk list")
            for chunk in chunks:
                require(set(chunk) == {"gitBlobSha1", "bytes", "sha256"}, "Unexpected chunk fields")
                require(isinstance(chunk["gitBlobSha1"], str) and re.fullmatch("[0-9a-f]{40}", chunk["gitBlobSha1"]), "Invalid Git blob SHA")
                require(isinstance(chunk["sha256"], str) and re.fullmatch("[0-9a-f]{64}", chunk["sha256"]), "Invalid chunk SHA256")
                require(type(chunk["bytes"]) is int and 0 < chunk["bytes"] <= 4 * 1024 * 1024, "Invalid chunk length")
            require(sum(chunk["bytes"] for chunk in chunks) == size, "Chunk lengths do not cover ZIP")
            assets.append(Asset(name, size, sha, entry["contentType"], tuple(chunks)))
    require(names == set(SPECS), "Asset set differs")
    notes = next(asset.local for asset in assets if asset.name == "ReleaseNotes-v1.0.2.md")
    marker = f"<!-- yingjing-yanwu-publisher:{TAG};source={SOURCE};manifest-sha256={digest(raw)} -->"
    return Plan(tuple(assets), marker + "\n\n" + notes.decode("utf-8").replace("\r\n", "\n"))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file, code, message, headers, url):
        return None  # Never forward a bearer token to an unreviewed redirect.


class GitHub:
    def __init__(self, token):
        require(bool(token), "GITHUB_TOKEN is missing")
        self.token = token
        self.opener = urllib.request.build_opener(NoRedirect)

    def request(self, method, path, body=None, raw=None, media=None, allow_missing=False):
        if path.startswith("https://"):
            parts = urllib.parse.urlsplit(path)
            require(parts.scheme == "https" and parts.netloc == "uploads.github.com"
                    and re.fullmatch(re.escape(PREFIX) + r"/releases/[1-9][0-9]*/assets", parts.path)
                    and not parts.fragment, "Upload endpoint differs")
            query = urllib.parse.parse_qs(parts.query, strict_parsing=True)
            require(set(query) == {"name"} and len(query["name"]) == 1 and query["name"][0] in SPECS, "Upload name differs")
            url = path
        else:
            require(path.startswith(PREFIX + "/") and "\r" not in path and "\n" not in path, "API path differs")
            url = "https://api.github.com" + path
        headers = {"Authorization": "Bearer " + self.token, "Accept": "application/vnd.github+json",
                   "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "yingjing-yanwu-release-v1.0.2"}
        data = None
        if body is not None:
            data = json.dumps(body, ensure_ascii=False).encode("utf-8")
            headers["Content-Type"] = "application/json"
        if raw is not None:
            data = raw
            headers["Content-Type"] = media
        if data is not None:
            headers["Content-Length"] = str(len(data))
        request = urllib.request.Request(url, data=data, headers=headers, method=method)
        attempts = 3 if method == "GET" else 1
        for attempt in range(attempts):
            try:
                with self.opener.open(request, timeout=90) as response:
                    result = response.read(8 * 1024 * 1024 + 1)
                require(len(result) <= 8 * 1024 * 1024, "API response exceeds bound")
                return json.loads(result.decode("utf-8"), object_pairs_hook=unique_object)
            except urllib.error.HTTPError as error:
                if error.code == 404 and allow_missing:
                    return None
                if method == "GET" and error.code in (429, 500, 502, 503, 504) and attempt + 1 < attempts:
                    try:
                        wait = max(1, int(error.headers.get("Retry-After", str(2 ** attempt))))
                    except ValueError:
                        wait = 2 ** attempt
                    require(wait <= 30, "API rate limit requires a later rerun")
                    time.sleep(wait)
                    continue
                # No upload retry, replacement or deletion after an uncertain response.
                raise PublicationError(f"GitHub {method} returned HTTP {error.code}; no automatic deletion/replacement; rerun verifies server state") from None


def positive_id(value):
    require(type(value) is int and value > 0, "Invalid API object ID")
    return value


def main_pin(api):
    result = api.request("GET", PREFIX + "/git/ref/heads/main")
    require(result["object"]["type"] == "commit" and result["object"]["sha"] == SOURCE, "main moved; publication refused")


def tag_pin(api, required=False):
    result = api.request("GET", PREFIX + "/git/ref/tags/" + TAG, allow_missing=True)
    if result is None:
        require(not required, "Expected tag is missing")
        return False
    target, visited = result["object"], set()
    for _ in range(8):
        require(isinstance(target.get("sha"), str) and re.fullmatch("[0-9a-f]{40}", target["sha"]), "Invalid tag object")
        if target["type"] == "commit":
            require(target["sha"] == SOURCE, "Tag points to another commit; never force-update it")
            return True
        require(target["type"] == "tag" and target["sha"] not in visited, "Invalid annotated tag chain")
        visited.add(target["sha"])
        target = api.request("GET", PREFIX + "/git/tags/" + target["sha"])["object"]
    raise PublicationError("Annotated tag chain is too deep")


def list_pages(api, path):
    results = []
    for page in range(1, 21):
        items = api.request("GET", path + f"?per_page=100&page={page}")
        require(isinstance(items, list), "Expected API list")
        results.extend(items)
        if len(items) < 100:
            return results
    raise PublicationError("API list exceeds reviewed bound")


def find_release(api):
    # Authenticated list includes resumable drafts; a tag endpoint alone is insufficient.
    found = [release for release in list_pages(api, PREFIX + "/releases") if release.get("tag_name") == TAG]
    require(len(found) <= 1, "Multiple releases use the target tag")
    return found[0] if found else None


def release_pin(release, plan, draft):
    positive_id(release["id"])
    require(release.get("tag_name") == TAG and release.get("target_commitish") == SOURCE
            and release.get("name") == TITLE and release.get("prerelease") is True
            and release.get("draft") is draft, "Existing release identity/state differs")
    if draft:
        require(release.get("body") == plan.body, "Draft body/manifest marker differs; refusing to adopt it")


def asset_pin(remote, asset):
    positive_id(remote["id"])
    require(remote.get("name") == asset.name and remote.get("size") == asset.size
            and remote.get("state") == "uploaded" and remote.get("digest") == "sha256:" + asset.sha256,
            "Existing/uploaded asset differs or digest is not ready; no replacement/deletion")


def assets_state(api, release, plan, complete=False):
    found = list_pages(api, PREFIX + f"/releases/{positive_id(release['id'])}/assets")
    desired = {asset.name: asset for asset in plan.assets}
    present = {}
    for remote in found:
        name = remote.get("name")
        require(name in desired and name not in present, "Unexpected/duplicate release asset; preserving release")
        asset_pin(remote, desired[name])
        present[name] = remote
    require(not complete or set(present) == set(desired), "Release assets are incomplete")
    return present


def materialize(api, asset):
    if asset.local is not None:
        raw = asset.local
    else:
        assembled = bytearray()
        for chunk in asset.chunks:
            result = api.request("GET", PREFIX + "/git/blobs/" + chunk["gitBlobSha1"])
            require(result.get("encoding") == "base64" and result.get("sha") == chunk["gitBlobSha1"]
                    and result.get("size") == chunk["bytes"] and isinstance(result.get("content"), str), "Blob metadata differs")
            try:
                data = base64.b64decode(result["content"].replace("\r", "").replace("\n", ""), validate=True)
            except ValueError:
                raise PublicationError("Invalid blob base64") from None
            require(len(data) == chunk["bytes"] and digest(data) == chunk["sha256"]
                    and git_blob_sha(data) == chunk["gitBlobSha1"], "Blob bytes/checksums differ")
            assembled.extend(data)
            require(len(assembled) <= asset.size, "Blob assembly exceeds asset length")
        raw = bytes(assembled)
    require(len(raw) == asset.size and digest(raw) == asset.sha256, "Complete asset length/SHA256 differs")
    return raw


def upload_url(release, name):
    url = release.get("upload_url", "").split("{", 1)[0]
    expected = f"https://uploads.github.com{PREFIX}/releases/{positive_id(release['id'])}/assets"
    require(url == expected, "Release upload URL differs")
    return url + "?" + urllib.parse.urlencode({"name": name})


def publish(api, plan):
    main_pin(api)
    tag_exists = tag_pin(api)
    release = find_release(api)
    if release and release.get("draft") is False:
        require(tag_exists, "Published release has no pinned tag")
        release_pin(release, plan, False)
        assets_state(api, release, plan, complete=True)
        return {"status": "already-published-verified", "releaseId": release["id"]}
    present = {}
    if release:
        release_pin(release, plan, True)
        present = assets_state(api, release, plan)
    # All bytes needed for this attempt are verified before the first API mutation.
    prepared = {asset.name: materialize(api, asset) for asset in plan.assets if asset.name not in present}
    main_pin(api)
    if not tag_pin(api):
        api.request("POST", PREFIX + "/git/refs", body={"ref": "refs/tags/" + TAG, "sha": SOURCE})
    tag_pin(api, required=True)
    if not release:
        release = api.request("POST", PREFIX + "/releases", body={"tag_name": TAG, "target_commitish": SOURCE,
            "name": TITLE, "body": plan.body, "draft": True, "prerelease": True, "make_latest": "false"})
        release_pin(release, plan, True)
    for asset in plan.assets:
        if asset.name in present:
            continue
        # Concurrency also includes manual UI/API edits outside this workflow.
        # Never upload after observing that the draft was already published.
        current = api.request("GET", PREFIX + f"/releases/{release['id']}")
        if current.get("draft") is False:
            release_pin(current, plan, False)
            assets_state(api, current, plan, complete=True)
            tag_pin(api, required=True)
            return {"status": "already-published-verified", "releaseId": current["id"]}
        release_pin(current, plan, True)
        present = assets_state(api, current, plan)
        if asset.name in present:
            continue
        uploaded = api.request("POST", upload_url(release, asset.name), raw=prepared[asset.name], media=asset.content_type)
        positive_id(uploaded["id"])
        for attempt in range(3):
            if uploaded.get("digest"):
                break
            time.sleep(1)
            uploaded = api.request("GET", PREFIX + f"/releases/assets/{uploaded['id']}")
        asset_pin(uploaded, asset)
    assets_state(api, release, plan, complete=True)
    main_pin(api)
    tag_pin(api, required=True)
    current = api.request("GET", PREFIX + f"/releases/{release['id']}")
    if current.get("draft") is False:
        release_pin(current, plan, False)
        assets_state(api, current, plan, complete=True)
        return {"status": "already-published-verified", "releaseId": current["id"]}
    release_pin(current, plan, True)
    published = api.request("PATCH", PREFIX + f"/releases/{release['id']}", body={"draft": False, "prerelease": True, "make_latest": "false"})
    release_pin(published, plan, False)
    assets_state(api, published, plan, complete=True)
    tag_pin(api, required=True)
    return {"status": "published-verified", "releaseId": published["id"]}


def main():
    require(len(sys.argv) == 1, "No command-line inputs are accepted")
    require(os.environ.get("GITHUB_REPOSITORY") == REPOSITORY
            and os.environ.get("GITHUB_EVENT_NAME") == "push"
            and os.environ.get("GITHUB_REF") == BRANCH, "Only the reviewed repository push branch is allowed")
    plan = load_plan(Path(__file__).resolve().parents[1])
    result = publish(GitHub(os.environ.get("GITHUB_TOKEN", "")), plan)
    result["url"] = f"https://github.com/{REPOSITORY}/releases/tag/{TAG}"
    print(json.dumps(result))


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(f"Publication stopped: {type(error).__name__}: {error}", file=sys.stderr)
        raise SystemExit(1)
