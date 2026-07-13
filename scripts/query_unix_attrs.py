#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "requests",
# ]
# ///
"""Query OktaPAM for the unix attributes (gid, group_name) of a single group.

Implements the Terraform external-data-source protocol:
  - Reads  {"group_name": "<name>"} from stdin
  - Writes {"gid": "<N>", "group_name": "<name>"} to stdout (all string values)

Environment variables (same as the okta/oktapam Terraform provider):
  TF_VAR_oktapam_key    | OKTAPAM_KEY
  TF_VAR_oktapam_secret | OKTAPAM_SECRET
  TF_VAR_oktapam_org    | OKTA_ORG    | OKTAPAM_ORG
  TF_VAR_oktapam_team   | OKTA_TEAM   | OKTAPAM_TEAM
  OKTAPAM_API_HOST  (optional) overrides https://{org}.pam.okta.com
"""
import json
import os
import sys
from urllib.parse import quote

import requests

TIMEOUT = 30
GID_ATTRS        = ("unix_gid", "posix_gid", "gid")
GROUP_NAME_ATTRS = ("unix_group_name", "posix_group_name", "group_name")


def env(*names, required=True, default=None):
    for n in names:
        v = os.environ.get(n)
        if v:
            return v
    if required:
        sys.exit(f"error: set one of [{', '.join(names)}] in the environment (.envrc)")
    return default


def get_bearer_token(host, team, key, secret):
    url = f"{host}/v1/teams/{team}/service_token"
    resp = requests.post(url, json={"key_id": key, "key_secret": secret}, timeout=TIMEOUT)
    if resp.status_code != 200:
        sys.exit(f"error: auth failed ({resp.status_code}) at {url}: {resp.text[:300]}")
    body = resp.json()
    token = body.get("bearer_token") or body.get("token")
    if not token:
        sys.exit(f"error: no bearer_token in auth response: {resp.text[:300]}")
    return token


def fetch_group_attributes(host, team, token, group_name):
    url = f"{host}/v1/teams/{team}/groups/{quote(group_name, safe='')}/attributes"
    resp = requests.get(url, headers={"Authorization": f"Bearer {token}"}, timeout=TIMEOUT)
    if resp.status_code == 404:
        return None
    if resp.status_code != 200:
        sys.exit(f"error: fetch attributes failed ({resp.status_code}) at {url}: {resp.text[:300]}")
    body = resp.json()
    raw = body.get("attributes")
    attrs = {}
    if isinstance(raw, dict):
        for name, meta in raw.items():
            attrs[name] = meta.get("attribute_value") if isinstance(meta, dict) else meta
    else:
        for a in (raw if isinstance(raw, list) else body.get("list", []) or []):
            if a.get("attribute_name"):
                attrs[a["attribute_name"]] = a.get("attribute_value")
    return attrs


def main():
    query = json.load(sys.stdin)
    group_name = query.get("group_name")
    if not group_name:
        sys.exit("error: 'group_name' missing from stdin JSON")

    key    = env("TF_VAR_oktapam_key",    "OKTAPAM_KEY")
    secret = env("TF_VAR_oktapam_secret", "OKTAPAM_SECRET")
    org    = env("TF_VAR_oktapam_org",    "OKTA_ORG",  "OKTAPAM_ORG")
    team   = env("TF_VAR_oktapam_team",   "OKTA_TEAM", "OKTAPAM_TEAM")
    host   = env("OKTAPAM_API_HOST", required=False,
                 default=f"https://{org}.pam.okta.com")

    token = get_bearer_token(host, team, key, secret)
    attrs = fetch_group_attributes(host, team, token, group_name)
    if attrs is None:
        sys.exit(f"error: group '{group_name}' not found in OktaPAM")

    gid          = next((str(attrs[a]) for a in GID_ATTRS        if a in attrs), "")
    resolved_name = next((str(attrs[a]) for a in GROUP_NAME_ATTRS if a in attrs), group_name)

    if not gid:
        sys.exit(f"error: no unix gid attribute found on group '{group_name}'")

    # External data source protocol: all output values must be strings.
    json.dump({"gid": gid, "group_name": resolved_name}, sys.stdout)


if __name__ == "__main__":
    main()
