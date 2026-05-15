# Remote Connectivity — Design Doc

**Status:** Considering. No code yet. This doc exists so we can
argue about scope, risks, and tradeoffs *before* writing 5,000+
lines that touch the streaming pipeline.

**Owner:** Eric.

**Last revised:** 2026-05-15.

---

## Problem

Today Reolens is a strict LAN client. Once the user leaves their
home network, every camera in the sidebar goes red — there is no
path to reach the device.

The official Reolink app works anywhere on the internet because
it speaks Reolink's proprietary P2P stack: a discovery-server +
hole-punch + relay design keyed on the camera's UID (the same UID
we already fetch in
[`Sources/ReolinkBaichuan/BaichuanUID.swift`](../Sources/ReolinkBaichuan/BaichuanUID.swift)).

Reolens has to either (a) implement that P2P stack itself, (b)
lean on user-managed alternatives (DDNS, Tailscale, etc.), or (c)
some combination. This doc argues for (c) with P2P as the
headline feature and the alternatives as documented fallbacks.

## Non-goals

- **A Reolens-operated relay.** The README's stance is "no Reolens
  server, no third-party analytics, no telemetry." Standing up a
  Reolens TURN cluster would break that, and bandwidth costs are
  meaningful for video.
- **Remote access without internet on the camera.** P2P needs the
  camera to be online and able to reach Reolink's discovery
  servers. Air-gapped LANs are out of scope.
- **Reverse-engineering Reolink's account system.** P2P needs only
  the camera UID + the device's own credentials. We do not need
  the user's Reolink cloud account.

## Background: how Reolink P2P actually works

Reverse-engineered by `thirtythreeforty/neolink` (Rust, GPLv3).
Their crate is our protocol reference — we cannot copy code
(GPL ↔ MIT incompatible), but the wire format is a fact and is
fair game to re-implement.

The pieces:

### 1. Discovery (rendezvous)

The camera continuously registers its (UID → public IP:port,
public IPv6:port, local LAN IP:port) tuple with one of Reolink's
keepalive servers. Known endpoints:

- `p2p.reolink.com`
- `p2p2.reolink.com` … `p2p9.reolink.com`
- Regional flavors: `p2p-na.reolink.com`, `p2p-eu.reolink.com`,
  `p2p-as.reolink.com`.

Clients query the same servers with the UID and a small XML
payload to retrieve the camera's *current* candidate list. The
candidate list is short-lived; we have to re-query when paths
go stale.

The discovery protocol rides on top of the same **BcUdp** packet
format (below) — it is not HTTP. Authentication is by knowing
the UID. There is no per-user secret at this layer; the camera
credentials gate the *next* layer, not the rendezvous.

### 2. NAT traversal (hole punching)

Classic STUN-style UDP hole punching:

1. Client and camera each send small "Disc" packets to each
   other's candidates simultaneously.
2. The first packet pair that survives a NAT round-trip wins —
   that 5-tuple becomes the data path.
3. Symmetric NATs on both sides defeat hole punching. We fall
   back to relay.

Practical NAT class coverage from neolink's experience: ~75–85 %
of consumer NATs succeed without relay; the long tail is
double-NAT (CGNAT, mobile carriers, some hotel/airport WiFi).

### 3. Relay fallback

When hole punching fails, the discovery server brokers a relay
through Reolink's TURN-like infrastructure. Traffic is rate-
limited and presumably observable by Reolink — same as the
official app.

### 4. BcUdp transport (the actual wire format)

Once a 5-tuple is established (direct or relayed), control and
video both flow as BcUdp packets:

```
+--------+--------+--------+--------+
| Magic  | Type   | Length          |  Type ∈ {Disc, Ack, Data}
+--------+--------+--------+--------+
| Connection ID (UID for Disc;      |
|  short connection-id for Data/Ack)|
+-----------------------------------+
| Packet seq                        |
+-----------------------------------+
| Payload …                         |
+-----------------------------------+
```

Reference: `neolink/crates/core/src/bcudp/` — codec.rs, model.rs.

- **Disc** packets carry discovery XML (lookup, candidate list,
  hole-punch hints).
- **Data** packets carry the same Baichuan messages we already
  encode in
  [`Sources/ReolinkBaichuan/Wire/BcMessage.swift`](../Sources/ReolinkBaichuan/Wire/BcMessage.swift)
  — login, video, PTZ, etc.
- **Ack** packets ack data sequence numbers. There's a
  selective-ack / retransmit loop because UDP doesn't have one.

So a fully working P2P stack is conceptually:

```
Reolens (BaichuanClient)
   ↓
[Transport] ← LAN: NWConnection over TCP/9000
            ← P2P: BcUdp framing over NWConnection.udp
                     ├─ direct path (post-hole-punch)
                     └─ relayed path (via Reolink TURN)
```

`BaichuanClient` shouldn't need to know which transport it's on
once the transport is up. That's the cleanest factoring.

### 5. Video: no RTSP, only Baichuan frames

Reolink P2P *does not* tunnel RTSP. There is no SDP. Video is
delivered as Baichuan `msg_id=3` data frames inside BcUdp Data
packets:

- Each msg_id=3 reply carries one chunk: a Baichuan video sub-
  header + raw H.264 or H.265 NALUs (Annex-B framing).
- We have to depacketize NALUs ourselves and feed them to
  `VTDecompressionSession`. The
  [`Sources/ReolinkStreaming/RTSP/`](../Sources/ReolinkStreaming/RTSP)
  H.264/H.265 NALU pipe is reusable for the *decode* half but
  the RTSP demuxer is bypassed entirely.
- Audio: Baichuan AAC frames in msg_id=3 just like the official
  app. Reuses our existing AVAudioEngine sink.

This is the single largest piece of the project: a second
"recorder" path that consumes msg_id=3 frames instead of RTP/AVP.

## Phased plan

Each phase is independently shippable. The user gets *some*
remote access at the end of Phase 0; full P2P parity arrives at
Phase 4.

### Phase 0: Manual remote address (1–2 days)

Add a "Remote address (DDNS / WAN)" optional field next to the
LAN address. If the LAN probe fails, fall through to the remote
address. No protocol work — just routing the existing CGI/RTSP
clients at a different hostname.

Ships immediately for users willing to port-forward or run
DDNS. Documented in a "Remote access" section of `README.md`
with the Tailscale recommendation up top.

**Files touched:**
- `Sources/ReolinkAPI/Camera.swift` — add `remoteHost`,
  `remotePort` to `CameraCredentials`.
- `App/Views/AddCamera*.swift` — second host field, collapsed
  behind a disclosure.
- `App/State/CameraReachability.swift` (new) — "is LAN
  reachable? if not, try remote" state machine.

**Risk:** Low. The CGI and RTSP clients don't care about the
hostname; they take whatever they're given.

### Phase 1: BcUdp packet codec + tests (3–5 days)

A new `Sources/ReolinkBcUdp/` module that knows nothing about
networking — just packet encode/decode.

```
ReolinkBcUdp/
  Wire/
    BcUdpHeader.swift     // magic / type / length / conn-id / seq
    BcUdpPacket.swift     // Disc / Data / Ack variants
    DiscoveryXML.swift    // <P2P> tag schema for Disc payloads
  ReolinkBcUdp.swift      // module docs + module-public entry
Tests/ReolinkBcUdpTests/  // round-trip vectors, captured from a
                          //   real device under tcpdump
```

**Acceptance:**
- 100 % round-trip on every captured packet in
  `Tests/ReolinkBcUdpTests/Fixtures/`.
- No network code. No actors. Pure value-type encoding.

**Risk:** Low. This is parser-grade work and is the layer
neolink has the cleanest public reference for.

### Phase 2: Discovery client (3–5 days)

A `P2PDiscovery` actor that, given a UID, queries the
`p2p*.reolink.com` cluster (UDP/9999, BcUdp Disc packets) and
returns a `Candidates` struct: `{ wanV4, wanV6, lanV4, relayHint }`.

**Acceptance:**
- Given a known-good UID and an internet connection, returns at
  least one candidate within 3 s.
- Falls through across the `p2p*` cluster on per-host timeout.
- Survives the discovery server replying with a "try this other
  server" redirect (Reolink balances load this way).

**Risk:** Medium. Server pool composition can change. Mitigated
by treating the bootstrap list as data, not hard-coded constants
— shipped in
`Sources/AppShared/Resources/p2p-bootstrap.json` so we can update
without an app release.

### Phase 3: NAT traversal + transport (1–2 weeks)

`RemoteTransport` actor: takes a `Candidates` payload, drives
hole punching, exposes the same `send(BcMessage)` /
`AsyncStream<BcMessage>` surface that
[`BaichuanClient`](../Sources/ReolinkBaichuan/BaichuanClient.swift)
expects today.

Refactor `BaichuanClient` to accept a `Transport` protocol
instead of holding an `NWConnection` directly. Existing TCP path
becomes `LANTransport: Transport`; new `RemoteTransport: Transport`
slots in alongside.

**Acceptance:**
- A working `LogIn → fetchUID → fetchVersion` round-trip over
  the remote transport against a real camera on a real residential
  NAT.
- Direct path preferred; if hole punching fails within 6 s,
  fall back to relay-hint candidate.
- Transparent to `BaichuanLogin`, `BaichuanBattery`, etc. — no
  changes in those files.

**Risk:** High. Requires real-device testing on multiple NATs.
This is where neolink users still occasionally report breakage.

### Phase 4: Baichuan video pipeline (1–2 weeks)

A new `BaichuanVideoSource` in `ReolinkStreaming` that consumes
`msg_id=3` frames over `RemoteTransport`, splits NALUs, and feeds
the existing `VideoDecoder` (VideoToolbox wrapper).

**Acceptance:**
- A camera reached via P2P plays main + sub stream in the grid
  with the same first-frame latency target as RTSP (≤ 600 ms p50
  on a healthy connection).
- Stream switch (main ↔ sub) works.
- Snapshot (`msg_id=109`) works.
- Talkback (`msg_id=202`) works.

**Risk:** High. Largest LOC delta of the project. May surface
codec edge cases on battery cameras (whose sub-stream timing
differs).

### Phase 5: UI surfacing (1–2 days)

- Connection-mode indicator on each camera tile: "LAN" (green),
  "P2P direct" (yellow), "P2P relayed" (orange). Tap → details
  sheet.
- Settings → Privacy & Sync → "Remote access" section explaining
  that P2P routes through Reolink's servers and that the LAN
  mode stays fully offline.
- Per-camera toggle: "Allow remote access (P2P)". Default off
  until the user opts in.

### Phase 6: Documentation + release (1 day)

- `README.md`: new "Remote access" section above "What you get".
  Lead with Tailscale (still the safest); document P2P as the
  zero-setup option.
- `SECURITY.md`: P2P threat model. Reolink's servers learn that
  *some* client reached *this* UID; they do not learn the
  credentials (we still log in to the camera ourselves once the
  transport is up). Credentials are TLS-encrypted? **No** —
  Baichuan login uses MD5'd nonces, not TLS. Same as LAN. Worth
  calling out.
- `CHANGELOG.md`: 0.7.0 entry.

## Total effort

5–7 weeks of focused work for one developer. Roughly:

| Phase | Effort | Cumulative |
|-------|--------|------------|
| 0     | 2 d    | 2 d        |
| 1     | 5 d    | 7 d        |
| 2     | 5 d    | 12 d       |
| 3     | 10 d   | 22 d       |
| 4     | 10 d   | 32 d       |
| 5     | 2 d    | 34 d       |
| 6     | 1 d    | 35 d       |

## Risks worth re-stating before we commit

### Reolink can break this any time

The `p2p*.reolink.com` cluster is private infrastructure. They
can rotate domains, change the BcUdp framing, require signed
clients, or block UIDs reported by non-official apps. The
mitigation is "ship updates fast" — there is no real defense.

### Reolink's terms of service

Reolink's device EULA likely prohibits reverse-engineered access
to their cloud services. neolink lives with this; so does
ReolinkRestApi (Python) and Home Assistant's reolink integration.
The risk is takedown rather than legal — we should not
advertise "uses Reolink P2P" loudly, the way neolink doesn't.
Call it "remote access" in the UI.

### Privacy stance shift

The README's "no third-party servers" line stops being literally
true once P2P is on. The honest framing:

> **LAN mode** routes only between your devices and your
> cameras. **Remote mode** additionally uses Reolink's discovery
> and (if hole-punching fails) relay servers to reach the camera
> when you're away from home. Remote mode is opt-in per camera.

That edit needs to land in both `README.md` and the in-app
About screen.

### Real-device testing surface

We need at least three NAT configurations to validate Phase 3:
home cable modem (full-cone), home fibre with CGNAT, mobile
hotspot (symmetric). The CI runners can't simulate this. The
dev loop will involve a real Reolink device on a real residential
internet connection.

### Battery cameras

Battery cameras (Argus, Reolink Go, Duo Battery) have a
different P2P keepalive cadence — they sleep and wake. The
discovery server tells us "device is sleeping; send wake hint";
the wake hint is an FCM-style push that Reolink's app delivers,
which we *cannot* mimic. Battery cameras may end up remote-only
when they happen to be awake. Worth a Settings note.

## Open questions

1. **Server-pool bootstrap.** Ship the `p2p*.reolink.com` list
   as a JSON resource, or hard-code? JSON wins for hot-fixing
   but adds a "where is this loaded from" question for
   reviewers.
2. **Relay opt-in.** Should we offer "direct-only, no relay"
   as a privacy setting? Power users may prefer "fail rather
   than send my video through Reolink's TURN".
3. **iCloud sync of remote settings.** Per-camera "Allow
   remote" lives in the existing `cameras.json` iCloud sync, but
   it implies the same toggle on every signed-in device. Good
   default; worth surfacing in the Settings copy.
4. **HKSV interaction.** If HomeKit Secure Video ever lands
   (see `docs/ROADMAP.md`), HKSV expects RTSP. The P2P path
   bypasses RTSP entirely. Either keep HKSV LAN-only or build a
   tiny local-loopback RTSP server fed by Baichuan frames. The
   second is plausible but out of scope for this project.

## What to do next

This doc is the gate. If we agree on the phased plan, the next
PR is Phase 0 — the manual remote-address field — because it
ships value to users in a day and is independent of every later
phase. Phase 1 (BcUdp codec) follows in the same release cycle.

Phases 2–4 are gated on whether we're willing to commit ~5 weeks
to a single feature and accept the privacy-stance edit to
`README.md` / About screen.

## References

- `thirtythreeforty/neolink` —
  https://github.com/thirtythreeforty/neolink (Rust, GPLv3) —
  protocol reference only, no code copied.
- `crates/core/src/bcudp/` in neolink — the BcUdp codec we will
  re-implement in Swift.
- `crates/core/src/bc_protocol/connection/discovery.rs` in
  neolink — the discovery state machine.
- Home Assistant `reolink` integration — uses the same camera
  CGI we already use, no P2P, useful for sanity checks on the
  control-plane half.
