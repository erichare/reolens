<!--
Thanks for sending a PR! Before opening, please confirm:

- [ ] You've read AGENTS.md (engineering principles).
- [ ] For non-trivial changes, there's an issue discussing the approach.
- [ ] swift build and swift test pass locally.
- [ ] If you changed a user-facing feature, all three platforms (macOS,
      iPadOS, iOS) work, OR there's a documented carve-out with rationale.
-->

## Summary

<!-- One or two sentences on what this changes and why. -->

## Test plan

<!-- Bulleted list of things you tested. Mention each platform you
verified on. -->

- [ ] `swift build` — macOS clean
- [ ] `xcodebuild -scheme ReolensiOS` — iOS clean
- [ ] `swift test` — passing
- [ ] Manually tested on (macOS / iPad / iPhone): ...

## Security

<!--
If this PR touches authentication, credential storage, networking,
iCloud sync, or anything else that handles user data, explicitly call
out what you reviewed:

  - What new attack surface (if any) does this add?
  - What credentials, tokens, or PII does this touch?
  - Does this change anything that would land in logs, crash reports,
    or iCloud Drive?

If the PR doesn't touch any of those, write "N/A — no auth / network /
credential / sync changes."
-->

## Platform parity

<!--
Per AGENTS.md §1, features ship everywhere or have a documented
carve-out. Confirm:

  - [ ] This works on macOS, iPadOS, and iPhone, OR
  - [ ] This is a documented platform-specific carve-out (explain why)

If the change only makes sense on one platform (e.g. Sparkle is
macOS-only because iOS uses TestFlight), say so explicitly.
-->

## Changelog entry

<!--
Add an entry under `## [Unreleased]` in CHANGELOG.md if this is a
user-visible change. The exact wording can be polished at release time.
-->

## Related issues

<!-- Links to issues this closes or references. -->
