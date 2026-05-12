# Security policy

Reolens handles live video feeds from users' own security cameras and
the credentials needed to authenticate to those cameras. We take
security reports seriously.

## Reporting a vulnerability

**Please do not file a public GitHub issue for security problems.**

Use one of these private channels instead:

1. **GitHub Security Advisories (preferred).** Open a draft advisory:
   https://github.com/jestatsio/reolens/security/advisories/new
   This keeps the discussion private until a fix is published.
2. **Email.** `security@reolens.io`. Include "Reolens security" in
   the subject. If you want to PGP-encrypt, ask in your first message
   and we'll share a key.

What to include in your report:

- A clear description of the issue and its impact (what an attacker
  could achieve).
- Reproduction steps. Minimum viable repro: app version, OS version,
  Reolink device model + firmware version, and the exact actions
  that trigger the vulnerability.
- Suggested mitigation if you have one (welcome but not required).

## Response timeline

- **48 hours** — first acknowledgment that we received the report.
- **7 days** — initial triage with a CVSS-style severity assessment
  and a rough fix timeline.
- **30 days** — fixed and released for issues we've confirmed as
  reproducible, unless the fix requires upstream coordination (e.g.
  a Reolink firmware change) — in which case we'll tell you the new
  ETA.

We'll keep you posted at each step and credit you in the
[`CHANGELOG.md`](CHANGELOG.md) entry for the fix, unless you'd rather
stay anonymous.

## What we consider a security issue

In scope:

- Credential exposure (host, username, password, session token) via
  logs, crash reports, sync, telemetry, or any output Reolens
  produces.
- Authentication bypass against Reolink devices.
- Local-network attacks against the app itself (e.g. malformed RTSP
  packets crashing the player, certificate-validation bypasses).
- Privilege escalation on the host OS via the app's entitlements.
- Tampering with the Sparkle update channel (signature bypass,
  appcast spoofing) or the App Store distribution.
- Privacy regressions: Reolens making network calls to anywhere other
  than your Reolink devices, iCloud, the Sparkle appcast, or Apple's
  own services.
- iCloud sync schema regressions that would expose camera passwords
  to other devices.

Out of scope:

- Issues in Reolink firmware itself — report those to Reolink.
- Issues that require a malicious app already running on the user's
  device with the same entitlements as Reolens.
- Theoretical issues without a concrete impact assessment (e.g. "you
  should use longer keys").
- Social engineering of the maintainers.

## Architectural baseline

Reolens enforces these properties at the architectural level. A bug
report alleging any of them is broken is automatically in scope:

1. **Camera passwords never leave the device.** They live in Keychain
   with `kSecAttrSynchronizable: false`; they are not written to
   `cameras.json`, `UserDefaults`, logs at any level, or any network
   payload other than RTSP/HTTP authentication to the specific
   Reolink device.
2. **iCloud sync carries metadata only.** `cameras.json` contains
   display name, host, port, username, grid layout, channel order,
   rotations — never a password.
3. **No third-party analytics, no remote crash reporting.** The app
   talks to your Reolink devices, iCloud, the Sparkle appcast
   (macOS), and Apple's TestFlight / App Store — that's it.
4. **Drag and intent payloads carry IDs, never credentials.** The
   `com.reolens.channelDrag`, `com.reolens.deviceDrag`, and App
   Intents `OpenCameraIntent` paths all transport only UUIDs / channel
   integers.

See [`AGENTS.md`](AGENTS.md) for the full engineering principles.

## Disclosure

Once a fix is released:

- The fix lands in a tagged release with the security note in
  `CHANGELOG.md`.
- The GitHub Security Advisory is published with the CVE if one was
  assigned.
- Reporters who consent are credited by name (or handle, or
  anonymously, as preferred).

## Supported versions

Only the latest minor release is supported with security fixes. We
will not backport to older minor releases.
