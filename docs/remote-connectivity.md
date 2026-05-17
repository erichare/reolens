# Remote Connectivity — Tailscale Setup Guide

Reolens is LAN-only. The app reaches your camera at its LAN IP and
never talks to Reolink's cloud, a DDNS provider, or any third-party
relay. To make a LAN-only app work when you're away from home, put
your phone *on* the LAN by joining an overlay network. **Tailscale**
is the recommended path.

This guide walks the full setup end-to-end. It assumes you have a
Reolink camera or Home Hub already paired in Reolens and working on
your home Wi-Fi, and that you want it to keep working when you leave
the house.

---

## Why Tailscale (and not DDNS / port forwarding)

The older "DDNS + port forwarding" pattern works but exposes the
camera's HTTP/RTSP/Baichuan ports to the public internet. Reolink
firmwares have a steady stream of CVEs and Reolink's hardware is a
common target for botnet scans. Even with the ports forwarded only
to your specific camera, you're trusting:

- Your free DDNS provider's uptime and the DNS record's integrity.
- Your router's port-forward rules to not regress on a firmware
  update.
- Reolink's firmware to handle malformed inbound requests safely.
- Your ISP to give you a routable WAN IP at all — many residential
  ISPs (most cellular, some fiber) now use **CGNAT**, which makes
  inbound connections impossible regardless of how cleverly you set
  up DDNS.

Tailscale sidesteps all of these. Your phone and a small always-on
LAN device join a **tailnet** — a private mesh network — and the
phone reaches the camera's LAN IP directly through the mesh. Zero
ports forwarded. Nothing on the public internet to scan. Works on
CGNAT'd connections. Tailscale's own infrastructure only handles
NAT-punching and keys; the camera video itself goes peer-to-peer.

Tailscale is **free** for personal use (100 devices, 3 users).
Self-hostable as **Headscale** if you'd rather not depend on
Tailscale, Inc.'s coordination server.

---

## What you need

1. **A Reolink camera or Home Hub** already paired in Reolens on
   your home Wi-Fi.
2. **An always-on device on the same LAN as the camera**, capable of
   running Tailscale as a *subnet router*. You probably already have
   one. In rough order of "least extra hardware":

   - **Apple TV** (4K, tvOS 17+) — runs the official Tailscale app,
     can act as a subnet router, never sleeps its network stack.
     The most ergonomic option in an Apple household.
   - **Your router**, if it runs UniFi (UDM Pro / Dream Router /
     OS 4+), OPNsense, pfSense, OpenWrt, MikroTik (recent
     RouterOS), AsusWRT-Merlin, or GL.iNet. All have native
     Tailscale integrations — typically one checkbox in the web UI.
   - **A NAS** (Synology, QNAP, Unraid, TrueNAS) — Tailscale ships
     official apps for each.
   - **A Mac mini, an old MacBook, or any always-on Mac.**
   - **A Raspberry Pi** (4, 5, or Zero 2 W) — the classic fallback,
     ~$15–50.
3. **A Tailscale account** (free, sign in with Apple / Google /
   GitHub at <https://tailscale.com>).
4. **The Tailscale app on every Apple device** you want to use
   Reolens from — iPhone, iPad, Mac. All from the App Store.

---

## Setup

### 1. Create a Tailscale account

Visit <https://tailscale.com> → Sign in → pick an identity provider.
The free Personal tier is fine.

### 2. Install Tailscale on your LAN-side device (the subnet router)

The steps differ slightly per device; the goal is the same: install
Tailscale, sign in, and enable "advertise routes" for your LAN's
CIDR.

#### Apple TV (recommended for most users)

1. App Store on the Apple TV → search "Tailscale" → Install.
2. Open the app. It shows a code and URL; visit the URL on your
   phone, sign in, and approve the Apple TV.
3. Back in the Apple TV app → **Settings → Advertise routes**.
4. Enter your home LAN's CIDR (e.g. `192.168.1.0/24`,
   `192.168.0.0/24`, or `10.0.0.0/24`). If you're not sure: look up
   the IP address your Reolink hub has. If it's `192.168.1.100`,
   your CIDR is `192.168.1.0/24`.
5. Save.

#### UniFi / OPNsense / pfSense / OpenWrt / GL.iNet

Each platform has its own UI, but the pattern is: install the
Tailscale plugin/app → sign in via the on-screen QR code → enable
"subnet routes" → enter your LAN CIDR. UniFi has a dedicated
Tailscale section under Network Settings; OPNsense/pfSense add a
"VPN: Tailscale" pane; OpenWrt installs via `opkg`; GL.iNet exposes a
single "Enable Tailscale" toggle plus a CIDR field.

#### Synology / QNAP / Unraid / TrueNAS

Install the Tailscale app from the platform's package manager. Sign
in, then enable subnet routing via the app's settings → advertise
your LAN CIDR.

#### Raspberry Pi (or any Linux)

```sh
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up --advertise-routes=192.168.1.0/24   # adjust CIDR
```

#### Mac

Install Tailscale from the App Store, sign in, and enable subnet
routing under Tailscale menu bar → Settings → "Use exit node and
subnet routes" → Advertise routes → enter the CIDR.

### 3. Approve the subnet route in the Tailscale admin console

This is a one-time step. Tailscale doesn't auto-approve subnet
routes — you confirm which routes are real.

1. Open <https://login.tailscale.com/admin/machines>.
2. Find the row for your subnet-router device (Apple TV / router /
   NAS / Pi).
3. Click the "⋯" menu → **Edit route settings**.
4. Toggle on the route you just advertised. Save.

### 4. Install Tailscale on every Apple device that runs Reolens

App Store → Tailscale → Install → sign in with the same account on
iPhone, iPad, and Mac. iOS installs a VPN configuration; approve it.

### 5. Test

1. Turn off your phone's Wi-Fi so you're on cellular (truly off-LAN).
2. Toggle Tailscale on.
3. In Safari, open `http://<your-hub's-LAN-IP>`. The Reolink web UI
   should load just as if you were home. If it does, the route is
   working.
4. Open Reolens. The hub appears online, live tiles play. Done.

You don't need to change anything in Reolens — there's no remote-host
field to fill in. The app dials the camera's LAN IP, and Tailscale
delivers the packets.

---

## Tips

- **Apple TV in standby is fine.** Tailscale on tvOS keeps the
  network stack alive even when the TV is "off" (as long as it's
  plugged in).
- **MagicDNS** (one toggle in the admin console) lets you reach
  tailnet devices by name — handy but not required for Reolens.
- **Don't enable "Use Exit Node"** unless you actually want *all*
  your phone's traffic routed through home. Subnet routing is what
  Reolens needs; exit-node routing is a different feature.
- **Family members** can join your tailnet for free (invite from the
  admin console) and Reolens will work for them too. Their phones do
  not need your Tailscale login.
- **CGNAT is not a problem** for Tailscale. The mesh punches through
  most NATs; in the rare cases it can't, it falls back to a relay.
  Latency is fine for video.
- **Headscale** is a community open-source coordination server if you
  want to fully self-host the control plane.

---

## Troubleshooting

**The Apple TV (or router / NAS) doesn't appear in the admin
console.** Make sure you signed in with the same Tailscale account
you're using on your phone. Some sign-in flows pick up the wrong
account if you have multiple identity providers linked.

**Subnet route approved but I still can't reach the LAN.** Confirm
the CIDR matches your home LAN. If your hub is `192.168.1.100`, the
CIDR is `192.168.1.0/24` — not `192.168.0.0/24`. Also check that
the iPhone is *not* on the same LAN's Wi-Fi while testing — on-LAN,
your phone reaches the hub directly without using Tailscale, so a
broken Tailscale config still appears to "work."

**Reolens shows the camera as offline off-LAN.** Open Safari on the
phone and try `http://<hub-LAN-IP>` first. If Safari can't reach it
either, the issue is Tailscale routing, not Reolens. If Safari works
but Reolens doesn't, force-quit Reolens and reopen — the session
may have cached an unreachable state.

**iOS keeps disconnecting Tailscale.** Settings → General → VPN &
Device Management → Tailscale → make sure "Connect On Demand" is
configured to your preference. By default Tailscale stays up.

**Live tile stutters.** Tailscale adds ~10–30 ms of latency depending
on whether the connection is direct or relayed. For video this is
unnoticeable, but if you see issues, check the Tailscale admin
console for the connection type — "direct" is best. If it's
"relayed (DERP)," some NAT/firewall is preventing the peer-to-peer
hole-punch; opening UDP port 41641 on your router fixes the
overwhelming majority of these cases.

---

## What about non-Tailscale options?

Tailscale isn't the only choice; the pattern is "overlay network +
LAN-side subnet router." Equivalents:

- **WireGuard** — the protocol Tailscale is built on. Roll your own
  if you want to skip the coordination server. More setup, more
  control.
- **ZeroTier** — older mesh-VPN alternative. Similar UX.
- **Cloudflare Tunnel** — HTTPS-only, so it does *not* work for
  RTSP or Baichuan. Skip for cameras.
- **Headscale** — drop-in self-hostable replacement for Tailscale's
  coordination server.

Reolens does not ship integration with any of these — it doesn't
need to. As long as something puts your phone and the camera on the
same routable network, Reolens just works.
