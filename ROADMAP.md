# Roadmap

How this widget compares with Palo Alto's official GlobalProtect app, and the
order in which the gaps will be closed. v1.0 means parity with everything the
official **Linux** app offers that openconnect can do. Windows/macOS-only
features and the hard networking tier are listed at the end.

Status legend: `[x]` shipped · `[ ]` planned · `~` partial

## Where v0.1 stands

### Already covered

Confirmed in code, or in NetworkManager's journal for a live tunnel:

- **Core path**: SAML/Google SSO in an embedded browser, session cookie reuse,
  connect, disconnect, sign out, status, statistics, desktop notifications.
- **IPSec (ESP over UDP) with SSL fallback**: openconnect negotiates an ESP
  session and falls back to HTTPS. The official app calls this "IPSec mode".
- **Routes and DNS pushed by the gateway**: NetworkManager applies the access
  routes and DNS servers from the gateway config (split-by-access-route works
  if the gateway pushes it).
- **HIP report and hourly re-check**: openconnect submits the report with the
  stock `hipreport.sh` and re-checks on the portal's interval. Same "host info
  only" scope as the official Linux app.
- **MTU**: openconnect calculates one when the gateway sends none.
- **Gateway choice by name**: via `--authgroup`, typed rather than picked.

Things the widget has that the official client lacks: a live throughput
sparkline, keyboard navigation, no root daemon, and NetworkManager ownership
(`nmcli connection down GlobalProtect` just works).

### Gaps, ranked by difficulty

**Easy** — hours each; existing openconnect or NetworkManager knobs plus a little UI

| Feature | What it takes |
|---|---|
| Stay up across link changes | `vpn.persistent yes` on the profile; openconnect re-uses the cookie until it expires |
| Rediscover network / refresh connection | Disconnect, then reconnect with the stored session |
| Connection details | Show ESP vs SSL, gateway IP, pushed routes and DNS |
| Host state view | Render the fields the HIP script sends |
| Collect logs bundle | Tar NetworkManager journal lines, state, deps; scrub cookies |
| Username/password login (LDAP/RADIUS) | openconnect supports it; add a form and skip the browser |
| Client certificate auth | NM `usercert`/`privkey` data keys and `--certificate` on the auth step |
| Proxy support | openconnect `--proxy` and the NM proxy key |
| SSL-only / disable ESP | `--no-dtls` behind a setting |

**Medium** — days; needs the portal config XML or system plumbing

| Feature | What it takes |
|---|---|
| Gateway list, manual picker, preferred gateway | POST `getconfig.esp` with the prelogin cookie, parse the gateway entries, add a dropdown |
| Best Available gateway | Above plus priority parsing and a TLS latency probe per gateway |
| Always-On (user-logon connect) | Connect at shell start and on NM "connectivity full" events; backoff and a "pause for N minutes" UX |
| Captive portal detection with delay | NM reports the "portal" connectivity state; wait and notify before connecting |
| Split DNS | systemd-resolved is the resolver, so `ipv4.dns-priority` and routing-only search domains on the profile do it |
| No direct access to local network | Route metrics or nftables rules on activation |
| MFA/OTP second prompts | Interactive prompt plumbing between openconnect and the panel |
| Default system browser for SAML | Register a `globalprotectcallback` URL scheme handler that hands the cookie to the CLI; the portal must be configured for that mode |
| Multiple portals | One NM profile per portal, settings schema change, a picker |
| HIP notifications | Surface the hipreportcheck result from the journal, or re-run the check |
| Configurable MTU | Dispatcher script or `--base-mtu`; the NM plugin has no key for it |
| IPv6 addressing | UI is easy; openconnect calls its GlobalProtect IPv6 support experimental |
| Portal-driven app settings | Parse `agent-config` for connect method, timeouts, HIP interval, allowed gateways |
| Welcome page | Fetch from the portal config and show it once |

**Hard** — weeks, or fighting openconnect and the kernel

| Feature | Why |
|---|---|
| Domain-based optimized split tunnel | DNS interception and dynamic host routes |
| Traffic enforcement / forwarding profiles (6.3.1) | Portal-defined nftables policy with exclusions |
| Enforce GlobalProtect for network access (kill switch) | nftables plus FQDN exclusions and a captive-portal grace period; Windows/macOS only officially |
| Internal host detection and internal gateways | Reverse-DNS probe on every network change, then a HIP-only session to an internal gateway, which openconnect cannot do without a tunnel |

## Releases

### v0.1.0 — Foundation (shipped 2026-09-10)

- [x] Bar widget and panel: switch, gateway, address, time connected, throughput
- [x] Google SSO in a themed GTK/WebKitGTK window; session persists
- [x] Portal session cookie in the GNOME keyring when the portal offers one
- [x] NetworkManager owns the tunnel; secrets over a 0600 file
- [x] HIP report, gateway by name, reported client OS, SAML at gateway or portal
- [x] Keyboard navigation, notifications, one-click dependency install

### v0.2 — Resilient

The tunnel survives the network, and you can see what it negotiated.

- [x] Stay up across link changes (`vpn.persistent`)
- [x] Rediscover network (disconnect + reconnect with the stored session)
- [x] Connection details: tunnel protocol (ESP/SSL), gateway IP, routes, DNS
- [ ] Host state view: what the HIP report says about this machine
- [ ] Log bundle and a debug logging setting

### v0.3 — Gateways

Pick where you land.

- [ ] Portal config fetch (`getconfig.esp`) and gateway list
- [ ] Manual gateway picker in the panel
- [ ] Preferred gateway
- [ ] Best Available: priority plus TLS latency probe

### v0.4 — Always-On

- [ ] User-logon connect method: connect at shell start and when connectivity returns
- [ ] Backoff and "pause for N minutes"
- [ ] Captive portal detection with notification delay
- [ ] Reconnect after suspend, with re-auth when the cookie expired

### v0.5 — Sign-in options

- [ ] Username/password (LDAP/RADIUS)
- [ ] MFA/OTP second prompts
- [ ] Client certificate authentication
- [ ] Default system browser for SAML (`globalprotectcallback` handler)
- [ ] Proxy support

### v0.6 — Network

- [ ] Split DNS through systemd-resolved
- [ ] No direct access to local network
- [ ] SSL-only toggle (disable ESP)
- [ ] MTU override
- [ ] IPv6 addressing in status and panel

### v0.7 — Portal-driven

- [ ] Multiple portals
- [ ] Portal-driven app settings (`agent-config`)
- [ ] HIP notifications
- [ ] Welcome page

### v1.0 — Parity

Everything above stable, and the widget stands on its own.

- [ ] Every setting editable in the panel (no `shell.json` hand edits)
- [ ] First-run flow polished end to end
- [ ] Test coverage for every CLI code path that talks to the portal
- [ ] README and troubleshooting rewritten for the full feature set

## Beyond 1.0

The hard tier, in the order they would be worth attempting:

1. Internal host detection and internal gateways
2. Enforce GlobalProtect for network access (kill switch)
3. Domain-based split tunnel
4. Traffic enforcement with forwarding profiles

## Not planned

- **Fuller HIP categories** (antivirus, disk encryption, firewall, patch
  state): the official Linux app sends host info only, and reporting more
  means fabricating compliance data. Portals that require it should be told
  the client is Linux.
- **Pre-logon, Kerberos SSO, smart cards, credential provider, Cloud Identity
  Engine, HIP remediation, Extend User Session, endpoint quarantine,
  portal-driven upgrades**: not in the official Linux app either, and
  openconnect has no GlobalProtect Kerberos path.

## Sources

- [GlobalProtect feature compatibility matrix](https://docs.paloaltonetworks.com/compatibility-matrix/globalprotect/what-features-does-globalprotect-support)
- [Use the GlobalProtect App for Linux](https://docs.paloaltonetworks.com/globalprotect/user-guide/6-2/globalprotect-app-for-linux/use-the-globalprotect-app-for-linux)
- [OpenConnect GlobalProtect support](https://www.infradead.org/openconnect/globalprotect.html)
- [GlobalProtect 6.3 new features](https://docs.paloaltonetworks.com/globalprotect/new-features/by-version/globalprotect/6-3)
