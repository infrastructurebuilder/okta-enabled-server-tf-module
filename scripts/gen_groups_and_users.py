#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "requests",
#   "pyyaml",
# ]
# ///
"""Generate a groups_and_users YAML/JSON file from OktaPAM group pairs.

Discovers matching *_user / *_admin group pairs (iboktagroup naming convention),
fetches their unix attributes and current membership, and writes the
groups_and_users structure consumed by update_users.yaml and the
okta_enabled_server cloud-init.

Output structure:
  groups_and_users:
    <base_name>:
      user_group_name:  string
      user_group_id:    int | null   # null if no unix_gid attribute is set
      users:            list[string]
      admin_group_name: string
      admin_group_id:   int | null
      admin_users:      list[string]

Environment variables (same as the okta/oktapam Terraform provider):
  TF_VAR_oktapam_key    | OKTAPAM_KEY
  TF_VAR_oktapam_secret | OKTAPAM_SECRET
  TF_VAR_oktapam_org    | OKTA_ORG    | OKTAPAM_ORG
  TF_VAR_oktapam_team   | OKTA_TEAM   | OKTAPAM_TEAM
  OKTAPAM_API_HOST  (optional) overrides https://{org}.pam.okta.com

Usage:
  gen_groups_and_users.py                        # YAML to stdout
  gen_groups_and_users.py -o /root/groups.yaml   # YAML to file
  gen_groups_and_users.py --json -o groups.json  # JSON (for ansible -e @file)
  gen_groups_and_users.py --groups gsoc,stofs    # filter to specific base names
"""
import argparse
import json
import os
import sys
from urllib.parse import quote

import requests
import yaml

TIMEOUT = 30
GID_ATTRS        = ("unix_gid", "posix_gid", "gid")
GROUP_NAME_ATTRS = ("unix_group_name", "posix_group_name", "group_name")

USER_SUFFIX  = "_user"
ADMIN_SUFFIX = "_admin"


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

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


def list_groups(host, team, token):
    """Return all non-deleted group names."""
    url = f"{host}/v1/teams/{team}/groups"
    headers = {"Authorization": f"Bearer {token}"}
    page_size, names, offset = 100, [], None
    while True:
        params = {"count": str(page_size)}
        if offset:
            params["offset"] = offset
        resp = requests.get(url, headers=headers, params=params, timeout=TIMEOUT)
        if resp.status_code != 200:
            sys.exit(f"error: list groups failed ({resp.status_code}): {resp.text[:300]}")
        body = resp.json()
        page = (body if isinstance(body, list)
                else body.get("groups")
                or next((v for v in body.values() if isinstance(v, list)), []))
        page = page or []
        names.extend(g["name"] for g in page if g.get("name") and not g.get("deleted_at"))
        if len(page) < page_size:
            break
        next_offset = page[-1].get("id")
        if not next_offset or next_offset == offset:
            break
        offset = next_offset
    return names


def fetch_group_attributes(host, team, token, group_name):
    """Return {attr_name: value} for a group, or None on 404."""
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


def fetch_group_users(host, team, token, group_name):
    """Return sorted list of active member usernames for a group."""
    url = f"{host}/v1/teams/{team}/groups/{quote(group_name, safe='')}/users"
    headers = {"Authorization": f"Bearer {token}"}
    page_size, names, offset = 100, [], None
    while True:
        params = {"count": str(page_size)}
        if offset:
            params["offset"] = offset
        resp = requests.get(url, headers=headers, params=params, timeout=TIMEOUT)
        if resp.status_code == 404:
            return []
        if resp.status_code != 200:
            sys.exit(f"error: list users failed ({resp.status_code}) at {url}: {resp.text[:300]}")
        page = resp.json().get("list") or []
        names.extend(u["name"] for u in page if u.get("name") and not u.get("deleted_at"))
        if len(page) < page_size:
            break
        next_offset = page[-1].get("id")
        if not next_offset or next_offset == offset:
            break
        offset = next_offset
    return sorted(set(names))


def coerce_gid(attrs):
    """Extract and coerce a positive integer GID from attribute dict, or None."""
    if not attrs:
        return None
    for key in GID_ATTRS:
        val = attrs.get(key)
        if val is None or isinstance(val, bool):
            continue
        if isinstance(val, int) and val > 0:
            return val
        if isinstance(val, str) and val.strip().isdigit():
            v = int(val)
            return v if v > 0 else None
    return None


def coerce_group_name(attrs, fallback):
    """Extract a unix group name from attribute dict, falling back to provided name."""
    if attrs:
        for key in GROUP_NAME_ATTRS:
            v = attrs.get(key)
            if v and isinstance(v, str):
                return v
    return fallback


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(
        description="Generate groups_and_users YAML/JSON from OktaPAM _user/_admin group pairs."
    )
    ap.add_argument("-o", "--output-file", default=None,
                    help="write output to FILE instead of stdout")
    ap.add_argument("--json", action="store_true",
                    help="output JSON instead of YAML (useful with ansible-playbook -e @file)")
    ap.add_argument("--groups", default=None,
                    help="comma-separated list of base group names to include (default: all pairs)")
    args = ap.parse_args()

    key    = env("TF_VAR_oktapam_key",    "OKTAPAM_KEY")
    secret = env("TF_VAR_oktapam_secret", "OKTAPAM_SECRET")
    org    = env("TF_VAR_oktapam_org",    "OKTA_ORG",  "OKTAPAM_ORG")
    team   = env("TF_VAR_oktapam_team",   "OKTA_TEAM", "OKTAPAM_TEAM")
    host   = env("OKTAPAM_API_HOST", required=False,
                 default=f"https://{org}.pam.okta.com").rstrip("/") # type: ignore

    filter_names = {n.strip() for n in args.groups.split(",")} if args.groups else None

    token = get_bearer_token(host, team, key, secret)
    all_names = list_groups(host, team, token)
    print(f"fetched {len(all_names)} group(s)", file=sys.stderr)

    # Find _user / _admin pairs
    user_groups  = {n[:-len(USER_SUFFIX)]:  n for n in all_names if n.endswith(USER_SUFFIX)}
    admin_groups = {n[:-len(ADMIN_SUFFIX)]: n for n in all_names if n.endswith(ADMIN_SUFFIX)}
    base_names   = sorted(user_groups.keys() & admin_groups.keys())

    if filter_names:
        missing = filter_names - set(base_names)
        if missing:
            sys.exit(f"error: no _user/_admin pair found for: {', '.join(sorted(missing))}")
        base_names = sorted(filter_names)

    if not base_names:
        sys.exit("error: no _user/_admin group pairs found in OktaPAM")

    print(f"discovered pairs: {', '.join(base_names)}", file=sys.stderr)

    result = {}
    for base in base_names:
        user_grp  = user_groups[base]
        admin_grp = admin_groups[base]

        print(f"  fetching {user_grp} ...", file=sys.stderr)
        user_attrs  = fetch_group_attributes(host, team, token, user_grp)  or {}
        print(f"  fetching {admin_grp} ...", file=sys.stderr)
        admin_attrs = fetch_group_attributes(host, team, token, admin_grp) or {}

        print(f"  members of {user_grp} ...", file=sys.stderr)
        users       = fetch_group_users(host, team, token, user_grp)
        print(f"  members of {admin_grp} ...", file=sys.stderr)
        admin_users = fetch_group_users(host, team, token, admin_grp)

        # admin_users are a subset of the user group in the playbook, so remove
        # them from the plain users list to avoid duplication in the output
        # (the playbook re-adds them when reconciling user group membership).
        admin_set        = set(admin_users)
        users_only       = sorted(u for u in users if u not in admin_set)

        result[base] = {
            "user_group_name":  coerce_group_name(user_attrs,  user_grp),
            "user_group_id":    coerce_gid(user_attrs),
            "users":            users_only,
            "admin_group_name": coerce_group_name(admin_attrs, admin_grp),
            "admin_group_id":   coerce_gid(admin_attrs),
            "admin_users":      admin_users,
        }

    document = {"groups_and_users": result}

    if args.json:
        text = json.dumps(document, indent=2)
    else:
        text = yaml.safe_dump(document, default_flow_style=False, sort_keys=False)

    if args.output_file:
        with open(args.output_file, "w") as fh:
            fh.write(text)
        print(f"wrote {args.output_file}", file=sys.stderr)
    else:
        sys.stdout.write(text)


if __name__ == "__main__":
    main()
