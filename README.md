# Omarchy GlobalProtect

A native [Omarchy](https://omarchy.org) bar widget for Palo Alto GlobalProtect
VPNs. One switch in the bar, a themed sign-in window, and NetworkManager owning
the tunnel: no root daemon, no password prompts once set up.

It was built for Google (SAML) single sign-on and grew to cover what the
official Linux client does: username/password portals with one-time-code
prompts, client certificates, gateway selection, Always-On, split DNS, and the
portal's own app settings. See [ROADMAP.md](ROADMAP.md) for the feature-by-feature
comparison.

## Features

- **Bar icon** that shows the tunnel state at a glance; **panel** with the switch,
  gateway, tunnel protocol (IPSec/ESP or SSL), addresses, time connected, routes,
  DNS in effect, and a live throughput sparkline.
- **Sign-in your way**: Google SSO in an embedded window that stays signed in, the
  system browser (`globalprotectcallback:` handler), or a themed username/password
  prompt with the portal's labels, keyring-remembered passwords, and dialogs for any
  second factor openconnect relays.
- **Gateways**: fetch the portal's list with priority and measured latency; *Best
  available* picks like the official client, or prefer one by clicking it.
- **Always-On** with backoff, captive-portal detection, pause/resume, and tunnel
  restoration after suspend or a drop, in either connect mode.
- **Network**: tunnel DNS through systemd-resolved (Omarchy's global DNS pin would
  otherwise discard it), SSL-only, MTU override, no direct access to the local
  network, IPv6.
- **Portal-driven**: the portal's connect method, MTU, and SSL-only apply themselves;
  multiple portals; HIP notifications; welcome page.
- **Troubleshooting**: host state view (what the HIP report claims), debug log, and
  a scrubbed log bundle.
- **Keyboard-first** like the stock panels.

## Install

```bash
omarchy plugin add https://github.com/brianirish/omarchy-globalprotect.git --enable --yes
```

The widget lands in the bar's right section (`omarchy bar move brianirish.globalprotect --section <left|center|right>` to move it).

It needs the NetworkManager OpenConnect plugin from the official Arch repos. The
panel offers an *Install* button (a polkit prompt appears); the equivalent command is:

```bash
pkexec pacman -S --needed networkmanager-openconnect
```

Everything else is already part of Omarchy: `openconnect` (pulled in by that
package), NetworkManager with systemd-resolved, Python with PyGObject, GTK 3,
WebKitGTK, `secret-tool`, `notify-send`, and `wl-copy`. Node is optional (it runs
the Model.js tests).

## First run

1. Open the panel and enter your portal host (for example `vpn.example.com`). Press Enter.
2. Flip the switch. A window titled *Sign in · your-portal* opens: Google's page, or
   a username/password prompt if the portal has no SSO. Finish; the window closes itself.
3. The bar icon fills in, a notification confirms the gateway, and the panel shows
   the session.
4. Optional: press `g` to fetch the portal's gateways and app settings, and click
   *Enable tunnel DNS* if the DNS row says "not applied".

To keep the sign-in window floating and centered, add this to `~/.config/hypr/hyprland.lua`:

```lua
o.window({ class = "^omarchy-globalprotect$" }, { float = true, center = true, size = "480 720" })
```

## Settings

Every setting is editable in the panel's *Settings* section and stored under this
widget's entry in `~/.config/omarchy/shell.json`.

| Key | Panel control | Default | What it does |
|-----|---------------|---------|--------------|
| `portal` | Setup field / *Add portal* | — | Portal host. Adding another host switches to it; each portal keeps its own session, gateways, and portal settings. |
| `gateway` | *Gateways* section | `""` (Best available) | Preferred gateway by name. Empty picks highest priority, then lowest TLS latency; manual-only gateways are never auto-picked. |
| `authInterface` | *Sign-in interface* | `auto` | Where the SAML sign-in happens: `auto` probes the gateway interface first, then the portal; `gateway` or `portal` forces one. |
| `clientOs` | *Reports as* | `win` | Client OS sent to the portal (`win`, `linux`, `mac`). Many portals only admit Windows and macOS. |
| `hipReport` | *HIP report* | off | Submit openconnect's stock `hipreport.sh`. *Host state* shows exactly what it claims. |
| `connectMethod` | *Always-On* | `on-demand` | `always-on` connects at login and whenever the network returns, with 30 s → 10 min backoff. |
| `pauseMinutes` | *Pause (min)* | 30 | How long Always-On pauses when you flip the switch off or cancel the sign-in (`p` resumes). |
| `followPortal` | *Follow the portal's settings* | on | Apply the portal's connect method, tunnel MTU, and SSL-only when it sets them. |
| `dnsMode` | *Tunnel DNS* | `auto` | `auto`: pushed search domains use the tunnel's DNS, or all queries on a full tunnel without domains; `split`: pushed domains only; `off`: resolver untouched. Needs the one-time polkit rule (*Enable tunnel DNS*). |
| `sslOnly` | *SSL only* | off | Never use ESP over UDP (`disable_udp`). |
| `mtu` | *MTU* | 0 | Tunnel MTU override; 0 lets openconnect decide. |
| `blockLan` | *No direct access to local network* | off | Route the physical interfaces' on-link subnets into the tunnel while connected. |
| `samlBrowser` | *System browser for SAML* | `embedded` | `system` signs in through the default browser; only when the portal advertises the default-browser flow. |
| `proxy` | *Proxy* | `""` | `http://host:port` for prelogin, config fetch, openconnect, and the tunnel. |
| `certificate`, `certificateKey` | *Certificate*, *Key* | `""` | Client certificate (and separate key) for TLS client auth everywhere. |
| `refreshIntervalSec` | *Refresh (s)* | 5 | Status poll interval while the panel is open (4× slower when closed). |
| `debug` | *Debug logging* | off | Append each connect step to `~/.local/state/omarchy-globalprotect/debug.log` (rotated at 1 MB, never secrets). |

## Keyboard

`j`/`k` or arrows move, `Enter` activates, `t` toggles the tunnel, `c` copies the
address, `n` rediscovers the network, `g` fetches or refreshes gateways, `p` pauses
or resumes Always-On, `w` shows the portal's welcome page, `l` collects logs, `s`
signs in again, `f` forgets the session, `Esc` closes, `Tab` switches panels.

## Command line

The CLI the panel drives is usable on its own; every subcommand accepts the same
options the settings map to (`--portal`, `--gateway`, `--client-os`, `--hip`,
`--auth-interface`, `--browser`, `--proxy`, `--certificate`, `--key`, `--ssl-only`,
`--mtu`, `--block-lan`, `--dns-mode`, `--debug`).

```bash
bin/omarchy-globalprotect status                       # state as JSON (never blocks on the network)
bin/omarchy-globalprotect connect --portal vpn.example.com
bin/omarchy-globalprotect disconnect
bin/omarchy-globalprotect login                        # sign in only, store the session
bin/omarchy-globalprotect forget [--remove]            # drop the session; --remove drops the portal too
bin/omarchy-globalprotect gateways --refresh --probe   # fetch the portal's gateways and settings, time each gateway
bin/omarchy-globalprotect pause --minutes 30           # pause Always-On on every bar (0 resumes)
bin/omarchy-globalprotect hip-report --client-os win   # what the HIP report claims (JSON)
bin/omarchy-globalprotect hip-status                   # last HIP check/submission from the journal
bin/omarchy-globalprotect welcome --show               # the portal's welcome page
bin/omarchy-globalprotect collect-logs                 # scrubbed troubleshooting tarball in ~/Downloads
```

Exit codes: 0 ok, 1 error, 2 cancelled by the user, 3 missing dependencies,
4 silent refresh impossible (`gateways --quiet`).

## How it works

```
Panel.qml ── Service.qml ──► bin/omarchy-globalprotect ──► nmcli / NetworkManager ──► nm-openconnect ──► openconnect
                                     │
                                     ├─► POST prelogin.esp (gateway or portal interface) → SAML request, or a password form
                                     ├─► sign-in: GTK + WebKitGTK window (Google), system browser + callback, or a credentials dialog
                                     ├─► openconnect --protocol=gp --authenticate  (unprivileged; prints COOKIE, CONNECT_URL, FINGERPRINT)
                                     │      password logins run it through a pty so second-factor prompts become dialogs
                                     ├─► nmcli connection up GlobalProtect passwd-file=<0600 file in $XDG_RUNTIME_DIR>
                                     └─► resolvectl dns/domain on the tunnel link (tunnel DNS), if the polkit rule is installed
```

Secrets only ever travel over stdin or that temporary file, never on a command
line, and the gateway's certificate fingerprint is pinned into the activation.
The NM profile `GlobalProtect` is a persistent system connection (the openconnect
plugin refuses user-private ones); Omarchy's wheel polkit rule lets you manage it
without a prompt.

Where things live:

| What | Where |
|------|-------|
| Settings | this widget's entry in `~/.config/omarchy/shell.json` |
| Current portal | `~/.local/state/omarchy-globalprotect/state.json` |
| Per-portal username, gateway, gateway list, portal settings | `~/.local/state/omarchy-globalprotect/portals/<host>.json` |
| Debug log | `~/.local/state/omarchy-globalprotect/debug.log` |
| Google session (WebKit website data) | `~/.local/share/omarchy-globalprotect/webkit/` (0700) |
| Portal session cookie, remembered passwords | GNOME keyring, `application=omarchy-globalprotect` |
| System-browser callback handler | `~/.local/share/applications/omarchy-globalprotect-callback.desktop` |
| Tunnel DNS polkit rule (optional, installed on request) | `/etc/polkit-1/rules.d/50-omarchy-globalprotect-resolved.rules` |
| NetworkManager profile | `nmcli connection show GlobalProtect` |

## Troubleshooting

- **A username/password prompt appears instead of Google** — the portal offered no
  SAML for the reported client OS. If it should have, switch *Reports as* to Linux
  or macOS.
- **Signed in, then "User input required in non-interactive mode"** — the gateway
  wants its own SAML sign-in. `auto` handles this; if you forced `portal`, switch
  the sign-in interface to `gateway`.
- **Internal hostnames do not resolve** — the DNS row says "not applied": click
  *Enable tunnel DNS* once (polkit prompt). Omarchy pins DNS globally otherwise.
- **The tunnel fails with a HIP or "host check" message** — turn on *HIP report*;
  *Host state* shows what is sent and *Last check* when the gateway last asked.
- **System browser mode never comes back** — the browser needs a one-time "open link
  with" confirmation, and the portal must be configured for the default-browser flow;
  the embedded window is the safe default.
- **The tunnel never comes up** — `journalctl -u NetworkManager -n 50` shows what
  openconnect said; `bin/omarchy-globalprotect connect --portal <host> --debug` in a
  terminal prints each phase.
- **Wrong or expired session** — *Forget session* in the panel, then connect again.
- **Reporting a problem** — turn on *Debug logging*, reproduce, then *Collect logs*
  (`l`). The tarball in `~/Downloads` holds status, profile, journals, the debug
  log, and the HIP preview, with cookies and passwords masked.

## Development

```bash
scripts/check          # py_compile + Python unit tests + Model.js tests (node) + omarchy plugin validate
```

The plugin directory is a plain git checkout; the shell hot-reloads QML on save
(run `omarchy restart shell` if a changed component type is still cached). Design
decisions are logged in `docs/superpowers/specs/`, the original build plan in
`docs/superpowers/plans/`, and the version plan in `ROADMAP.md`.

## License

MIT
