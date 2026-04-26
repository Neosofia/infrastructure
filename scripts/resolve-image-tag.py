#!/usr/bin/env python3
"""Resolve a CalVer release tag for a given commit SHA.

Shared across all services — lives in the infrastructure repo and is
checked out by each service's GHA deploy workflow.

Usage:
    resolve-image-tag.py <sha> <repo> <github_token> <service_name>

    sha           - commit SHA from the triggering workflow_run event
    repo          - GitHub repository (owner/repo)
    github_token  - token with contents:read scope
    service_name  - tag prefix to match (e.g. "authentication")
                    Matches tags of the form <service_name>/<version>

Writes the bare version string (e.g. 2026.04.26) to $GITHUB_OUTPUT as
`value=`, or an empty value if no matching tag exists (branch build, not
a release).  Exits 0 in both cases so the caller can decide whether to
proceed.
"""

import json
import os
import sys
import urllib.request

sha, repo, token, service_name = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
tag_prefix = f"{service_name}/"


def api_get(url):
    r = urllib.request.Request(
        url,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
        },
    )
    with urllib.request.urlopen(r) as resp:
        return json.load(resp)


refs = api_get(f"https://api.github.com/repos/{repo}/git/refs/tags")

tag = ""
for r in refs:
    if tag_prefix not in r["ref"]:
        continue

    obj_sha = r["object"]["sha"]
    obj_type = r["object"]["type"]

    # Annotated tags point to a tag object, not directly to a commit.
    # Dereference to get the commit SHA before comparing.
    if obj_type == "tag":
        tag_obj = api_get(
            f"https://api.github.com/repos/{repo}/git/tags/{obj_sha}"
        )
        obj_sha = tag_obj["object"]["sha"]

    if obj_sha == sha:
        tag = r["ref"].replace(f"refs/tags/{tag_prefix}", "")
        break

output_file = os.environ.get("GITHUB_OUTPUT", "/dev/stdout")
with open(output_file, "a") as f:
    f.write(f"value={tag}\n")

if not tag:
    print(
        f"No {tag_prefix}* tag found for sha {sha} — skipping deploy (branch build, not a release)",
        file=sys.stderr,
    )
