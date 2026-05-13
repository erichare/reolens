#!/usr/bin/env python3
"""Ensure a provisioning profile exists for our app, via the App Store
Connect REST API.

Why: xcodebuild's "automatic" signing in Xcode 26 either silently picks
the wrong profile type (iOS App Development on a CI runner with no
registered devices) or refuses to embed an iCloud-capable profile in
Developer ID Direct macOS builds. Both failure modes leave us with an
app whose entitlements claim capabilities the bundle isn't provisioned
for, and AMFI rejects the launch.

Workaround: drop to manual signing and pre-create the right profile via
the API. This script does the API dance — idempotent, safe to run on
every build.

Two flavors covered, selected by env `PLATFORM`:

  PLATFORM=IOS  (default)
    - profile type:    IOS_APP_STORE
    - cert type:       DISTRIBUTION  (Apple Distribution)
    - bundle id:       IOS_BUNDLE_ID  (e.g. com.reolens.Reolens.iOS)
    - profile name:    PROFILE_NAME   (e.g. "Reolens iOS App Store")

  PLATFORM=MAC
    - profile type:    MAC_APP_DIRECT  (Developer ID Direct distribution)
    - cert type:       DEVELOPER_ID_APPLICATION
    - bundle id:       MAC_BUNDLE_ID  (e.g. com.reolens.Reolens)
    - profile name:    PROFILE_NAME   (e.g. "Reolens macOS Developer ID")

Common env (both flavors):
  AC_API_KEY_ID         — ASC API key id (10-char)
  AC_API_ISSUER_ID      — issuer UUID
  AC_API_KEY_P8_PATH    — path to the .p8 private key on disk
  ASC_CERT_SERIAL_NUMBER — optional local signing certificate serial;
                          when set, the ASC certificate must match it

Output:
  stdout — three lines:
             line 1: the profile name (caller pipes to
                     PROVISIONING_PROFILE_SPECIFIER or to ExportOptions
                     .plist's provisioningProfiles map)
             line 2: the absolute path to the .mobileprovision on disk
                     (caller can `cp` it into Contents/embedded.provisionprofile)
             line 3: the profile UUID (caller can pin
                     PROVISIONING_PROFILE to avoid stale same-name profiles)
  stderr — diagnostics

Side effect:
  Writes the .mobileprovision into
  ~/Library/MobileDevice/Provisioning Profiles/<UUID>.mobileprovision
  (the canonical location xcodebuild looks in)
"""
from __future__ import annotations

import base64
import json
import os
import plistlib
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from pathlib import Path

try:
    import jwt
except ImportError:
    sys.exit("error: pip install pyjwt cryptography")


API = "https://api.appstoreconnect.apple.com/v1"


@dataclass(frozen=True)
class Flavor:
    """Per-platform settings: which profile type to look up/create, which
    cert type to attach, which bundle-id env var holds the identifier,
    and which Apple platform to register the bundle id under."""

    platform_label: str
    profile_type: str
    cert_type: str
    bundle_env_var: str
    bundle_platform: str  # ASC API value: IOS, MAC_OS, UNIVERSAL
    default_profile_name: str


FLAVORS: dict[str, Flavor] = {
    "IOS": Flavor(
        platform_label="iOS App Store",
        profile_type="IOS_APP_STORE",
        cert_type="DISTRIBUTION",
        bundle_env_var="IOS_BUNDLE_ID",
        bundle_platform="IOS",
        default_profile_name="Reolens iOS App Store",
    ),
    "IOS_WIDGETS": Flavor(
        platform_label="iOS App Store (Widgets extension)",
        profile_type="IOS_APP_STORE",
        cert_type="DISTRIBUTION",
        bundle_env_var="IOS_WIDGETS_BUNDLE_ID",
        bundle_platform="IOS",
        default_profile_name="Reolens iOS Widgets App Store",
    ),
    "MAC": Flavor(
        platform_label="macOS Developer ID (Direct)",
        profile_type="MAC_APP_DIRECT",
        cert_type="DEVELOPER_ID_APPLICATION",
        bundle_env_var="MAC_BUNDLE_ID",
        bundle_platform="MAC_OS",
        default_profile_name="Reolens macOS Developer ID",
    ),
}


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


def _query(params: dict[str, str]) -> str:
    """Build a URL query string with values percent-encoded.

    We can't use urlencode() because it would also encode the keys —
    ASC's filter syntax uses literal square brackets like
    `filter[name]` which the API is happiest to receive un-escaped.
    Spaces and other control characters in *values* (e.g. profile
    names like "Reolens iOS App Store") MUST be encoded though,
    otherwise Python 3.14's stricter `http.client._validate_path`
    raises `InvalidURL`.
    """
    return "&".join(f"{k}={urllib.parse.quote(str(v), safe='')}" for k, v in params.items())


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


def find_bundle_id_resource(bundle_id: str, platform: str) -> str:
    """Return the ASC resource id for our bundle id (creates if missing).

    ASC's `filter[identifier]` is a *prefix* match, not exact — asking
    for `com.reolens.Reolens` happily returns
    `com.reolens.Reolens.iOS` if that's the only thing registered. We
    iterate up to a page of results and only accept an exact match;
    otherwise we treat the bundle as missing and try to POST. If the
    POST fails (often does, because creating bundle ids needs Admin
    role just like profiles), we exit with the precise developer-portal
    URL the maintainer should visit to register it manually.
    """
    res = request(
        "GET",
        # Bump limit so the prefix-match noise doesn't push the exact
        # match off the page. 200 is the API max.
        "/bundleIds?" + _query({"filter[identifier]": bundle_id, "limit": 200}),
    )
    for entry in (res.get("data") or []):
        if (entry.get("attributes") or {}).get("identifier") == bundle_id:
            return entry["id"]

    sys.stderr.write(f"    bundleId {bundle_id} not registered — creating ({platform})\n")
    try:
        res = request(
            "POST",
            "/bundleIds",
            body={
                "data": {
                    "type": "bundleIds",
                    "attributes": {
                        "identifier": bundle_id,
                        "name": bundle_id.replace(".", " "),
                        "platform": platform,
                    },
                }
            },
        )
    except urllib.error.HTTPError as e:
        if e.code == 403:
            sys.exit(
                "\n"
                "  ⚠️  ASC API rejected POST /v1/bundleIds with 403 FORBIDDEN.\n"
                "\n"
                f"  Bundle id '{bundle_id}' isn't registered in your Apple\n"
                "  Developer account, and your ASC API key doesn't have\n"
                "  permission to create one. Bundle id creation needs the\n"
                "  Admin role (App Manager doesn't cut it). Same constraint\n"
                "  applies to provisioning profiles.\n"
                "\n"
                "  Easiest fix — register it manually, once:\n"
                "    https://developer.apple.com/account/resources/identifiers/list/bundleId\n"
                "    • '+' → App IDs → App\n"
                f"    • Description: 'Reolens {platform}'\n"
                "    • Bundle ID: Explicit\n"
                f"    • Identifier: '{bundle_id}'\n"
                "    • Capabilities: enable any your entitlements need\n"
                "      (e.g. iCloud — and don't forget to attach the\n"
                "      iCloud container under 'Edit / Configure')\n"
                "\n"
                "  Then re-run; the script's GET path will pick it up.\n"
            )
        raise
    return res["data"]["id"]


def find_certificate_id(cert_type: str) -> str:
    """Return the resource id of a certificate of the given type.

    cert_type is the ASC API enum, e.g. DISTRIBUTION or
    DEVELOPER_ID_APPLICATION.
    """
    res = request(
        "GET",
        "/certificates?" + _query({"filter[certificateType]": cert_type, "limit": 200}),
    )
    data = res.get("data") or []
    if not data:
        sys.exit(
            f"error: no {cert_type} certificate found on the team.\n"
            "  Create one once via Xcode → Settings → Accounts → Manage\n"
            "  Certificates → '+' (the matching kind), then re-run."
        )

    expected_serial = normalized_serial(os.environ.get("ASC_CERT_SERIAL_NUMBER"))
    if expected_serial:
        for cert in data:
            attrs = cert.get("attributes") or {}
            if normalized_serial(attrs.get("serialNumber")) == expected_serial:
                return cert["id"]

        found = ", ".join(
            normalized_serial((cert.get("attributes") or {}).get("serialNumber"))
            or "<missing>"
            for cert in data
        )
        sys.exit(
            f"error: no {cert_type} certificate in ASC matches local serial "
            f"{expected_serial}.\n"
            f"  ASC returned serials: {found}\n"
            "  Re-export the Apple Distribution .p12 from the certificate "
            "shown in developer.apple.com, or revoke the stale cert/profile."
        )
    return data[0]["id"]


def normalized_serial(serial: str | None) -> str:
    """Normalize certificate serials from Keychain / ASC for comparison."""
    hex_serial = "".join(ch for ch in (serial or "").upper() if ch in "0123456789ABCDEF")
    return hex_serial.lstrip("0") or ("0" if hex_serial else "")


def find_or_create_profile(
    name: str,
    profile_type: str,
    bundle_id_resource: str,
    cert_id: str,
) -> tuple[str, str]:
    """Return (profile_name, profile_id) for the matching active profile.

    Looks for an active profile with the right name + type + bundle id +
    certificate; creates one if missing. The bundle/certificate check
    matters because profile names are not enough to identify a usable
    profile after a certificate rotation.
    """
    res = request(
        "GET",
        "/profiles?" + _query({"filter[name]": name, "limit": 10}),
    )
    stale_same_name_profile = False
    for p in res.get("data") or []:
        attrs = p.get("attributes", {})
        if (
            attrs.get("name") == name
            and attrs.get("profileType") == profile_type
            and attrs.get("profileState") == "ACTIVE"
        ):
            profile_id = p["id"]
            if profile_matches(profile_id, bundle_id_resource, cert_id):
                return name, profile_id
            sys.stderr.write(
                f"    profile {name!r} ({profile_id}) is active but tied to "
                "a different bundle id or certificate — creating a fresh one\n"
            )
            stale_same_name_profile = True

    if stale_same_name_profile:
        scoped_name = profile_name_for_certificate(name, cert_id)
        res = request(
            "GET",
            "/profiles?" + _query({"filter[name]": scoped_name, "limit": 10}),
        )
        for p in res.get("data") or []:
            attrs = p.get("attributes", {})
            if (
                attrs.get("name") == scoped_name
                and attrs.get("profileType") == profile_type
                and attrs.get("profileState") == "ACTIVE"
            ):
                profile_id = p["id"]
                if profile_matches(profile_id, bundle_id_resource, cert_id):
                    return scoped_name, profile_id
        sys.stderr.write(f"    using cert-specific profile name {scoped_name!r}\n")
        name = scoped_name

    sys.stderr.write(f"    profile {name!r} ({profile_type}) missing — creating\n")
    try:
        res = request(
            "POST",
            "/profiles",
            body={
                "data": {
                    "type": "profiles",
                    "attributes": {
                        "name": name,
                        "profileType": profile_type,
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
    except urllib.error.HTTPError as e:
        if e.code == 403:
            sys.exit(
                "\n"
                "  ⚠️  ASC API rejected POST /v1/profiles with 403 FORBIDDEN.\n"
                "\n"
                "  Your ASC API key has Read permission on profiles\n"
                "  (which is why the pre-flight check passed) but not\n"
                "  Write/Create. Profile creation requires the Admin role,\n"
                "  but ASC API keys can't be promoted after the fact.\n"
                "\n"
                "  Two ways to unblock:\n"
                "\n"
                "  (a) FAST — pre-create the profile manually, once:\n"
                f"      • https://developer.apple.com/account/resources/profiles/add\n"
                f"      • Type: pick the one matching {profile_type}\n"
                f"        (e.g. Distribution → App Store for IOS_APP_STORE)\n"
                f"      • App ID: the bundle id this script just used\n"
                f"      • Certificate: the matching Apple Distribution / Developer ID cert\n"
                f"      • Profile Name: '{name}'  (must match exactly)\n"
                "      • Generate. The script will then find it on the next run\n"
                "        without ever hitting the POST.\n"
                "\n"
                "  (b) PROPER — recreate the ASC API key with Admin role:\n"
                "      • https://appstoreconnect.apple.com/access/integrations/api\n"
                "      • Generate API Key → Access: Admin → download .p8\n"
                "      • Update GitHub secrets AC_API_KEY_ID and\n"
                "        AC_API_KEY_P8_BASE64 (issuer id stays the same)\n"
            )
        raise
    return name, res["data"]["id"]


def profile_matches(profile_id: str, bundle_id_resource: str, cert_id: str) -> bool:
    """Return true when an existing profile belongs to this bundle + cert."""
    bundle = request("GET", f"/profiles/{profile_id}/relationships/bundleId")
    if ((bundle.get("data") or {}).get("id")) != bundle_id_resource:
        return False

    certs = request("GET", f"/profiles/{profile_id}/relationships/certificates")
    return any(cert.get("id") == cert_id for cert in certs.get("data") or [])


def profile_name_for_certificate(base_name: str, cert_id: str) -> str:
    """Return a stable non-ambiguous profile name for cert rotations."""
    serial = normalized_serial(os.environ.get("ASC_CERT_SERIAL_NUMBER"))
    suffix = (serial[-8:] if serial else cert_id[:8]).upper()
    return f"{base_name} {suffix}"


def download_profile(profile_id: str) -> tuple[str, str]:
    """Fetch the .mobileprovision bytes, install into the profiles dir.

    Returns the path the profile was written to and its UUID.
    """
    res = request("GET", f"/profiles/{profile_id}")
    content_b64 = res["data"]["attributes"]["profileContent"]
    raw = base64.b64decode(content_b64)

    uuid = parse_uuid(raw)
    dest_dir = Path.home() / "Library" / "MobileDevice" / "Provisioning Profiles"
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / f"{uuid}.mobileprovision"
    dest.write_bytes(raw)
    return str(dest), uuid


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
    platform = (os.environ.get("PLATFORM") or "IOS").upper()
    if platform not in FLAVORS:
        sys.exit(f"error: PLATFORM must be IOS or MAC, got {platform!r}")
    flavor = FLAVORS[platform]

    bundle_id = (
        os.environ.get(flavor.bundle_env_var)
        or os.environ.get("IOS_BUNDLE_ID")  # back-compat for the iOS-only call sites
        or "com.reolens.Reolens.iOS"
    )
    profile_name = os.environ.get("PROFILE_NAME") or flavor.default_profile_name

    sys.stderr.write(
        f"==> Ensuring {flavor.platform_label} profile {profile_name!r} for {bundle_id}\n"
    )

    bundle_resource = find_bundle_id_resource(bundle_id, flavor.bundle_platform)
    sys.stderr.write(f"    bundleId resource: {bundle_resource}\n")

    cert_id = find_certificate_id(flavor.cert_type)
    sys.stderr.write(f"    {flavor.cert_type} cert: {cert_id}\n")

    name, profile_id = find_or_create_profile(
        profile_name, flavor.profile_type, bundle_resource, cert_id
    )
    sys.stderr.write(f"    profile: {name} ({profile_id})\n")

    dest, uuid = download_profile(profile_id)
    sys.stderr.write(f"    installed: {dest}\n")

    print(name)
    print(dest)
    print(uuid)
    return 0


if __name__ == "__main__":
    sys.exit(main())
