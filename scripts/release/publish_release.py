#!/usr/bin/env python3
"""Publish one already-built Brainstorm archive to Gitea and GitHub."""

import json
import os
import sys
from pathlib import Path
from typing import Any
from urllib.error import HTTPError
from urllib.parse import quote
from urllib.request import Request, urlopen


def die(message: str) -> None:
    raise SystemExit(message)


def request(url: str, token: str, method: str = "GET", payload: dict[str, Any] | None = None, expected: tuple[int, ...] = (200,)) -> tuple[Any, int, dict[str, str]]:
    body = json.dumps(payload).encode("utf-8") if payload is not None else None
    headers = {"Accept": "application/vnd.github+json", "Authorization": f"token {token}"}
    if body is not None:
        headers["Content-Type"] = "application/json"
    try:
        with urlopen(Request(url, data=body, headers=headers, method=method), timeout=120) as response:
            raw = response.read()
            parsed = json.loads(raw.decode("utf-8")) if raw else None
            if response.status not in expected:
                die(f"{method} {url} returned HTTP {response.status}: {raw.decode('utf-8', 'replace')}")
            return parsed, response.status, dict(response.headers.items())
    except HTTPError as error:
        raw = error.read().decode("utf-8", "replace")
        if error.code in expected:
            return None, error.code, dict(error.headers.items())
        die(f"{method} {url} returned HTTP {error.code}: {raw}")


def upload(url: str, token: str, path: Path) -> Any:
    headers = {
        "Accept": "application/vnd.github+json",
        "Authorization": f"token {token}",
        "Content-Type": "application/octet-stream",
    }
    with urlopen(Request(url, data=path.read_bytes(), headers=headers, method="POST"), timeout=600) as response:
        raw = response.read()
        if response.status not in (200, 201):
            die(f"Asset upload for {path.name} returned HTTP {response.status}: {raw.decode('utf-8', 'replace')}")
        return json.loads(raw.decode("utf-8"))


def release(base: str, repository: str, token: str, tag: str, commit: str, version: str, body: str) -> dict[str, Any]:
    endpoint = f"{base}/repos/{repository}/releases/tags/{quote(tag, safe='')}"
    existing, status, _ = request(endpoint, token, expected=(200, 404))
    payload = {
        "tag_name": tag,
        "target_commitish": commit,
        "name": f"Brainstorm {version}",
        "body": body,
        "draft": False,
        "prerelease": False,
    }
    if status == 404:
        created, _, _ = request(f"{base}/repos/{repository}/releases", token, "POST", payload, (201,))
        if not isinstance(created, dict):
            die(f"{repository} did not return the created release.")
        return created
    updated, _, _ = request(f"{base}/repos/{repository}/releases/{existing['id']}", token, "PATCH", payload, (200,))
    if not isinstance(updated, dict):
        die(f"{repository} did not return the updated release.")
    return updated


def replace_assets(service: str, repository: str, release_payload: dict[str, Any], token: str, files: list[Path]) -> None:
    release_id = release_payload["id"]
    if service == "gitea":
        base = os.environ["GITEA_SERVER_URL"].rstrip("/") + "/api/v1"
        assets, _, _ = request(f"{base}/repos/{repository}/releases/{release_id}/assets", token)
        existing = {asset["name"]: asset for asset in assets or []}
        for path in files:
            if path.name in existing:
                request(f"{base}/repos/{repository}/releases/{release_id}/assets/{existing[path.name]['id']}", token, "DELETE", expected=(204,))
            upload(f"{base}/repos/{repository}/releases/{release_id}/assets?name={quote(path.name, safe='')}", token, path)
        return

    assets = release_payload.get("assets", [])
    existing = {asset["name"]: asset for asset in assets}
    base = "https://api.github.com"
    for path in files:
        if path.name in existing:
            request(f"{base}/repos/{repository}/releases/assets/{existing[path.name]['id']}", token, "DELETE", expected=(204,))
        upload_url = release_payload["upload_url"].split("{")[0]
        upload(f"{upload_url}?name={quote(path.name, safe='')}", token, path)


def main() -> None:
    manifest_path = Path(sys.argv[1]).resolve()
    data = json.loads(manifest_path.read_text(encoding="utf-8"))
    required = ("version", "build", "tag", "source_commit", "archive", "sha256")
    if any(not data.get(key) for key in required):
        die("Release manifest is incomplete.")
    if data.get("gatekeeper_status") != "accepted" or data.get("notarized") is not True:
        die("Refusing to publish an artifact that Gatekeeper has not accepted after notarization.")

    archive = manifest_path.parent / data["archive"]
    checksum = archive.with_suffix(archive.suffix + ".sha256")
    signature = manifest_path.parent / "signature.txt"
    gatekeeper = manifest_path.parent / "gatekeeper.txt"
    files = [archive, checksum, manifest_path, signature, gatekeeper]
    if any(not path.is_file() for path in files):
        die("Release artifact set is incomplete.")

    body = f"Developer ID signed Brainstorm {data['version']} (build {data['build']}).\n\nSHA-256: `{data['sha256']}`"
    gitea_base = os.environ["GITEA_SERVER_URL"].rstrip("/") + "/api/v1"
    gitea = release(gitea_base, os.environ["GITEA_REPOSITORY"], os.environ["BRAINSTORM_GITEA_TOKEN"], data["tag"], data["source_commit"], data["version"], body)
    github = release("https://api.github.com", os.environ["GITHUB_REPOSITORY"], os.environ["BRAINSTORM_GITHUB_TOKEN"], data["tag"], data["source_commit"], data["version"], body)
    replace_assets("gitea", os.environ["GITEA_REPOSITORY"], gitea, os.environ["BRAINSTORM_GITEA_TOKEN"], files)
    replace_assets("github", os.environ["GITHUB_REPOSITORY"], github, os.environ["BRAINSTORM_GITHUB_TOKEN"], files)
    print(json.dumps({"gitea_release": gitea.get("html_url"), "github_release": github.get("html_url"), "tag": data["tag"]}, sort_keys=True))


if __name__ == "__main__":
    main()
