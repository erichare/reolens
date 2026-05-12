#!/usr/bin/env python3
"""Ensure an App Store iOS provisioning profile exists for our bundle ID.

xcodebuild's "automatic" signing in Xcode 26 reliably picks the *wrong*
profile type (iOS App Development) when archiving on a CI runner with no
registered devices, and silently ignores command-line CODE_SIGN_IDENTITY
overrides. The workaround is to drop to manual signing — but manual
signing requires the profile to already exist.

This script talks to the App Store Connect API to:
  1. Find the Apple Distribution certificate for the team.
  2. Find or create the IOS_APP_STORE provisioning profile for the
     configured bundle ID, attached to that certificate.
  3. Download the profile bytes into
     ~/Library/MobileDevice/Provisioning Profiles/<UUID>.mobileprovision
     so xcodebuild can find it by PROVISIONING_PROFILE_SPECIFIER.
  4. Print the profile *name* on stdout — callers pipe this into
     PROVISIONING_PROFILE_SPECIFIER.

Env required:
  AC_API_KEY_ID         — ASC API key id (10-char)
  AC_API_ISSUER_ID      — issuer UUID
  AC_API_KEY_P8_PATH    — path to the .p8 private key on disk
  IOS_BUNDLE_ID         — e.g. com.reolens.Reolens.iOS
  PROFILE_NAME          — what to name the profile, e.g. "Reolens iOS App Store"

The script is idempotent — repeated runs are no-ops once the profile
exists. It does NOT create the Apple Distribution certificate (cert
creation requires a CSR + private key, which only makes sense to do
locally where the user has the keychain).
"""
from __future__ import annotations

import base64
import json
import os
import plistlib
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

try:
    import jwt
except ImportError:
    sys.exit("error: pip install pyjwt cryptography")


API = "https://api.appstoreconnect.apple.com/v1"
PROFILE_TYPE = "IOS_APP_STORE"
CERT_TYPE = "DISTRIBUTION"


def jwt_token() -> str:
    """Build a 10-minute JWT for the ASC API."""
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


def request(method: str, path: str, body: dict | None = None) -> dict:
    """Hit the ASC API. Raises with the response body on non-2xx."""
    token = jwt_token()
    url = path if path.startswith("https://") else API + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        url,
        data=data,
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
        sys.stderr.write(
            f"ASC API {method} {path} -> {e.code}\n"
            f"  body: {e.read().decode('utf-8', 'ignore')[:600]}\n"
        )
        raise


def find_bundle_id_resource(bundle_id: str) -> str:
    """Return the ASC resource id for our bundle id (creates if missing)."""
    # ASC's filter[identifier] is exact-match.
    res = request(
        "GET",
        f"/bundleIds?filter[identifier]={bundle_id}&limit=1",
    )
    data = res.get("data") or []
    if data:
        return data[0]["id"]

    sys.stderr.write(f"    bundleId {bundle_id} not registered — creating\n")
    res = request(
        "POST",
        "/bundleIds",
        body={
            "data": {
                "type": "bundleIds",
                "attributes": {
                    "identifier": bundle_id,
                    "name": bundle_id.replace(".", " "),
                    "platform": "IOS",
                },
            }
        },
    )
    return res["data"]["id"]


def find_distribution_cert_id() -> str:
    """Return the resource id of the first Apple Distribution cert."""
    res = request(
        "GET",
        # `certificateType` is the API's filter param. We accept either
        # DISTRIBUTION (legacy iPhone Distribution) or IOS_DISTRIBUTION or
        # the unified DISTRIBUTION cert that Xcode 11+ uses (also called
        # "Apple Distribution").
        "/certificates?filter[certificateType]=DISTRIBUTION&limit=20",
    )
    data = res.get("data") or []
    if not data:
        sys.exit(
            "error: no Apple Distribution certificate found on the team.\n"
            "  Create one once via Xcode → Settings → Accounts → Manage\n"
            "  Certificates → '+' → 'Apple Distribution', then re-run."
        )
    return data[0]["id"]


def find_or_create_profile(
    name: str, bundle_id_resource: str, cert_id: str
) -> tuple[str, str]:
    """Return (profile_name, profile_id) for the matching App Store profile.

    Looks for an active profile with the right name + type; creates one
    if missing.
    """
    res = request(
        "GET",
        f"/profiles?filter[name]={name}&limit=10&include=bundleId",
    )
    for p in res.get("data") or []:
        attrs = p.get("attributes", {})
        if (
            attrs.get("name") == name
            and attrs.get("profileType") == PROFILE_TYPE
            and attrs.get("profileState") == "ACTIVE"
        ):
            return name, p["id"]

    sys.stderr.write(f"    profile {name!r} missing — creating\n")
    res = request(
        "POST",
        "/profiles",
        body={
            "data": {
                "type": "profiles",
                "attributes": {
                    "name": name,
                    "profileType": PROFILE_TYPE,
                },
                "relationships": {
                    "bundleId": {
                        "data": {"type": "bundleIds", "id": bundle_id_resource}
                    },
                    "certificates": {
                        "data": [{"type": "certificates", "id": cert_id}]
                    },
                },
            }
        },
    )
    return name, res["data"]["id"]


def download_profile(profile_id: str) -> str:
    """Fetch the .mobileprovision bytes, install into the profiles dir.

    Returns the path the profile was written to.
    """
    res = request("GET", f"/profiles/{profile_id}")
    content_b64 = res["data"]["attributes"]["profileContent"]
    raw = base64.b64decode(content_b64)

    # The bundle is a CMS-signed blob; the embedded XML plist sits between
    # the markers. We pull the UUID out so we can name the file
    # canonically — Xcode looks up profiles by UUID, not by filename.
    uuid = parse_uuid(raw)
    dest_dir = Path.home() / "Library" / "MobileDevice" / "Provisioning Profiles"
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / f"{uuid}.mobileprovision"
    dest.write_bytes(raw)
    return str(dest)


def parse_uuid(raw: bytes) -> str:
    """Extract the UUID from a .mobileprovision file's signed plist."""
    start = raw.find(b"<?xml")
    end = raw.find(b"</plist>")
    if start < 0 or end < 0:
        sys.exit("error: profile bytes don't contain an XML plist")
    plist = plistlib.loads(raw[start : end + len(b"</plist>")])
    uuid = plist.get("UUID")
    if not uuid:
        sys.exit("error: profile plist has no UUID")
    return uuid


def main() -> int:
    bundle_id = os.environ.get("IOS_BUNDLE_ID") or "com.reolens.Reolens.iOS"
    profile_name = os.environ.get("PROFILE_NAME") or "Reolens iOS App Store"

    sys.stderr.write(f"==> Ensuring App Store profile {profile_name!r} for {bundle_id}\n")

    bundle_resource = find_bundle_id_resource(bundle_id)
    sys.stderr.write(f"    bundleId resource: {bundle_resource}\n")

    cert_id = find_distribution_cert_id()
    sys.stderr.write(f"    distribution cert: {cert_id}\n")

    name, profile_id = find_or_create_profile(profile_name, bundle_resource, cert_id)
    sys.stderr.write(f"    profile: {name} ({profile_id})\n")

    dest = download_profile(profile_id)
    sys.stderr.write(f"    installed: {dest}\n")

    # stdout = profile name, so the shell can capture it cleanly.
    print(name)
    return 0


if __name__ == "__main__":
    sys.exit(main())
