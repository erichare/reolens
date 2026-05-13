#!/usr/bin/env python3
"""List every ASC provisioning profile, with optional name filter.

When `asc_ensure_profile.py` fails with a 409 "Multiple profiles
found with the name …", Apple's portal usually shows fewer profiles
than the API counts — revoked profiles stay in the database as
INVALID and continue to block the name. This script dumps EVERY
profile (state + type + bundle id + cert ids) so you can see exactly
what to delete.

Requires only read access on profiles (the same access the
ensure-profile pre-flight check uses).

Usage:

    AC_API_KEY_ID=...                                            \\
    AC_API_ISSUER_ID=...                                         \\
    AC_API_KEY_P8_PATH=~/Downloads/AuthKey_XXXXXXXXXX.p8         \\
    ./Scripts/asc_list_profiles.py                               # all profiles

    ./Scripts/asc_list_profiles.py "Reolens iOS App Store"       # filter by name

    ./Scripts/asc_list_profiles.py --delete <profile-id>         # destructive
    ./Scripts/asc_list_profiles.py --delete-by-name "Foo" --state INVALID

Delete needs the Admin role on the API key (same constraint as
creating profiles in `asc_ensure_profile.py`); the script will
surface the 403 if not.
"""
from __future__ import annotations

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

try:
    import jwt
except ImportError:
    sys.exit("error: pip install pyjwt cryptography")


API = "https://api.appstoreconnect.apple.com/v1"


def jwt_token() -> str:
    key_id = os.environ["AC_API_KEY_ID"]
    issuer = os.environ["AC_API_ISSUER_ID"]
    key_path = os.environ["AC_API_KEY_P8_PATH"]
    with open(key_path, "rb") as f:
        key = f.read()
    return jwt.encode(
        {"iss": issuer, "exp": int(time.time()) + 600, "aud": "appstoreconnect-v1"},
        key,
        algorithm="ES256",
        headers={"kid": key_id, "typ": "JWT"},
    )


def request(method: str, path: str) -> dict:
    token = jwt_token()
    url = path if path.startswith("https://") else API + path
    req = urllib.request.Request(
        url,
        method=method,
        headers={
            "Authorization": "Bearer " + token,
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            text = r.read().decode("utf-8")
            return json.loads(text) if text else {}
    except urllib.error.HTTPError as e:
        sys.stderr.write(f"ASC API {method} {path} -> {e.code}\n")
        sys.stderr.write(f"  body: {e.read().decode('utf-8', 'ignore')[:600]}\n")
        raise


def list_profiles(name_filter: str | None) -> list[dict]:
    """Return every profile (paginated). `name_filter` is a substring
    match applied client-side, since ASC's `filter[name]` is exact."""
    out: list[dict] = []
    # ASC's profiles endpoint isn't filterable by state — so we just
    # pull all of them and filter client-side. `include=bundleId` so
    # each row carries the bundle identifier without a follow-up
    # request.
    next_url = "/profiles?limit=200&include=bundleId"
    while next_url:
        res = request("GET", next_url)
        for entry in (res.get("data") or []):
            attrs = entry.get("attributes", {})
            if name_filter and name_filter.lower() not in (attrs.get("name") or "").lower():
                continue
            # Resolve the bundle id via the included resources.
            bundle_id = "?"
            try:
                bundle_ref = entry["relationships"]["bundleId"]["data"]
                if bundle_ref:
                    for inc in res.get("included") or []:
                        if inc["id"] == bundle_ref["id"] and inc["type"] == "bundleIds":
                            bundle_id = inc["attributes"].get("identifier", "?")
                            break
            except (KeyError, TypeError):
                pass
            out.append({
                "id": entry["id"],
                "name": attrs.get("name"),
                "type": attrs.get("profileType"),
                "state": attrs.get("profileState"),
                "uuid": attrs.get("uuid"),
                "bundle": bundle_id,
                "expires": attrs.get("expirationDate"),
            })
        next_url = ((res.get("links") or {}).get("next"))
    return out


def delete_profile(profile_id: str) -> None:
    request("DELETE", f"/profiles/{profile_id}")


def main() -> int:
    argv = sys.argv[1:]

    # --delete <id>: remove a single profile by ASC id.
    if argv and argv[0] == "--delete":
        if len(argv) != 2:
            sys.exit("usage: asc_list_profiles.py --delete <profile-id>")
        sys.stderr.write(f"DELETE /v1/profiles/{argv[1]}\n")
        delete_profile(argv[1])
        sys.stderr.write("  done.\n")
        return 0

    # --delete-by-name "<name>" [--state STATE]: bulk-delete every
    # profile matching the given name (and optional state). Useful for
    # cleaning out a pile of revoked duplicates after a name collision.
    if argv and argv[0] == "--delete-by-name":
        if len(argv) < 2:
            sys.exit('usage: asc_list_profiles.py --delete-by-name "<name>" [--state STATE]')
        name = argv[1]
        state_filter: str | None = None
        if "--state" in argv:
            state_filter = argv[argv.index("--state") + 1]
        matches = [p for p in list_profiles(name)
                   if p["name"] == name and (state_filter is None or p["state"] == state_filter)]
        if not matches:
            sys.stderr.write(f"no profiles matched name={name!r} state={state_filter!r}\n")
            return 0
        sys.stderr.write(f"deleting {len(matches)} profile(s) matching name={name!r} state={state_filter!r}:\n")
        for m in matches:
            sys.stderr.write(f"  • id={m['id']} state={m['state']} type={m['type']} bundle={m['bundle']}\n")
            delete_profile(m["id"])
        sys.stderr.write("  done.\n")
        return 0

    # Default: list, optionally filtering by a name substring.
    name_filter = argv[0] if argv else None
    profiles = list_profiles(name_filter)
    if not profiles:
        sys.stderr.write("(no profiles matched)\n")
        return 0
    # Render as a fixed-width table for quick eyeballing.
    headers = ("id", "state", "type", "bundle", "name", "uuid")
    widths = {
        "id": max(len(p["id"]) for p in profiles) + 2,
        "state": 10,
        "type": 22,
        "bundle": max(len(p["bundle"]) for p in profiles) + 2,
        "name": max(len(p["name"] or "") for p in profiles) + 2,
        "uuid": 38,
    }
    line = "".join(h.ljust(widths[h]) for h in headers)
    sys.stdout.write(line + "\n")
    sys.stdout.write("-" * len(line) + "\n")
    for p in profiles:
        row = (
            p["id"].ljust(widths["id"]),
            (p["state"] or "").ljust(widths["state"]),
            (p["type"] or "").ljust(widths["type"]),
            (p["bundle"] or "").ljust(widths["bundle"]),
            (p["name"] or "").ljust(widths["name"]),
            (p["uuid"] or "").ljust(widths["uuid"]),
        )
        sys.stdout.write("".join(row) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
