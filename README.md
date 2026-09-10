# Omarchy GlobalProtect

A native [Omarchy](https://omarchy.org) bar widget for Palo Alto GlobalProtect
VPNs, built for Google (SAML) single sign-on and also happy with plain
username/password portals, one-time-code prompts, and client certificates. One switch in the bar, a themed
Google sign-in window, and NetworkManager owning the tunnel — no root helper,
no password prompts once installed.

- **Bar icon** that shows the tunnel state at a glance: dimmed when off, a
  gentle pulse while connecting, a badge when something failed.
- **Panel** with the connection switch, the gateway, the tunnel protocol (IPSec/ESP
  or SSL), your VPN address (click to copy), time connected, routes, DNS, and a
  live throughput sparkline.
- **Google stays signed in** inside the sign-in window, so reconnecting is
  usually a window that flashes and closes. When the portal hands back a
  reusable session cookie it is kept in your keyring and reused until it expires.
- **Keyboard-first** like the stock panels: `j`/`k` move, `Enter` activates,
  `t` toggles, `c` copies the address, `n` rediscovers the network, `g` refreshes gateways, `p` pauses or resumes Always-On, `l` collects logs, `s` signs in again, `f` forgets the session, `Esc` closes.
- **NetworkManager owns the tunnel**, so routes, DNS, and teardown behave like any
  other NM VPN, and `nmcli connection down GlobalProtect` works from a terminal too.
  The profile is persistent: a Wi-Fi roam, cable swap, or resume from suspend makes
  openconnect reconnect with the same session instead of dropping the tunnel. If the
  tunnel still drops, the widget restores it (signing in again if the session expired).
- **Always-On** (optional): connect at login and whenever the network comes back, with
  30 s → 10 min backoff on failures, a captive-portal notice instead of a doomed attempt,
  and a pause (default 30 min, `p`) when you flip the switch off.

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

Everything else it uses is already part of Omarchy: `openconnect` (pulled in by
the package above), NetworkManager, Python with PyGObject, GTK 3, WebKitGTK,
`secret-tool`, `notify-send`, and `wl-copy`.

## First run

1. Open the panel and enter your portal host (for example `vpn.example.com`). Press Enter.
2. Flip the switch. A window titled *Sign in · your-portal* opens with Google's
   sign-in page. Finish signing in; the window closes itself.
3. The bar icon fills in, a notification confirms the gateway, and the panel
   shows the session.

If the portal refuses the connection, check the panel's settings section:

- **Sign-in interface** (`authInterface` in `shell.json`, default `auto`): some
  deployments require the SAML sign-in at the *gateway* (`/ssl-vpn/prelogin.esp`)
  rather than the portal, and hand out no reusable portal cookie. `auto` probes
  the gateway interface on your host first and falls back to the portal; force
  `gateway` or `portal` if you know which one you need.
- **Gateways**: the panel's *Gateways* section lists the portal's gateways with
  priority and measured latency once you fetch them (`g`; this signs in at the
  portal, so the Google window may flash). *Best available* picks the highest
  priority, then the lowest latency, like the official client; click a gateway to
  prefer it instead. With the gateway sign-in interface the SSO happens at the
  chosen gateway's host; with the portal interface it is passed as `--authgroup`.
- **HIP report**: turn on if your portal requires a host-integrity report. This
  submits openconnect's stock `hipreport.sh`. The panel's *Host state* section
  shows exactly what that script claims (reporting as Windows lists stock McAfee,
  Defender, and Windows tooling entries; as Linux it lists cryptsetup, iptables,
  nftables, and DNF).
- **Reported client OS** (`clientOs` in `shell.json`, default `win`): many portals
  only allow Windows and macOS clients. Set it to `linux` if yours accepts Linux.
- **Username/password portals**: when the portal offers no SAML, a themed prompt asks
  for the credentials the portal labels (LDAP/RADIUS). Tick *Remember* to keep the
  password in the GNOME keyring; a wrong stored password is dropped and asked again.
  Any second prompt openconnect relays (one-time code, push approval, challenge) opens
  the same kind of dialog.
- **System browser for SAML** (`samlBrowser: system`): the sign-in opens in your default
  browser and the portal returns the session through a `globalprotectcallback:` link.
  The widget registers itself as the handler for that scheme. Only works when the portal
  is configured for the default-browser flow; the embedded window is the safe default.
- **Client certificate** (`certificate`, `certificateKey`): used for prelogin, the portal
  config fetch, `openconnect`, and the NetworkManager profile (`usercert`/`privkey`).
- **Proxy** (`proxy`): an `http://host:port` URL used for prelogin, the config fetch,
  `openconnect`, and the tunnel.
- **Tunnel DNS** (`dnsMode`: `auto`, `split`, `off`): Omarchy pins DNS globally through
  NetworkManager, which silently discards the DNS servers a gateway pushes, so internal
  hostnames would not resolve. The panel offers *Enable tunnel DNS*, a one-time polkit
  prompt that installs a small rule letting the widget set the tunnel link's DNS in
  systemd-resolved. `auto` routes the pushed search domains to the tunnel's DNS (and
  everything, on a full tunnel that pushes no domains); `split` only ever routes the
  pushed domains; `off` leaves the resolver alone. The DNS row shows what is in effect.
- **SSL only** (`sslOnly`), **MTU override** (`mtu`), **No direct access to local
  network** (`blockLan`): the official client's tunnel settings. The LAN block routes the
  physical interfaces' on-link subnets into the tunnel while connected.
- **IPv6**: the tunnel's global IPv6 address shows next to the IPv4 one when the gateway
  assigns one (openconnect's GlobalProtect IPv6 support is still marked experimental).
- **Connect method** (`connectMethod`: `on-demand` or `always-on`, and `pauseMinutes`):
  the *Always-On* toggle in the panel. Turning the switch off while Always-On pauses it
  for `pauseMinutes`; cancelling the sign-in window does the same.

To keep the sign-in window floating and centered, add this to `~/.config/hypr/hyprland.lua`:

```lua
o.window({ class = "^omarchy-globalprotect$" }, { float = true, center = true, size = "480 720" })
```

## How it works

```
Panel.qml ── Service.qml ──► bin/omarchy-globalprotect ──► nmcli / NetworkManager ──► nm-openconnect ──► openconnect
                                     │
                                     ├─► POST https://<host>/ssl-vpn/prelogin.esp (gateway) or /global-protect/prelogin.esp (portal) → SAML request
                                     ├─► GTK + WebKitGTK window: Google SSO → prelogin-cookie / portal-userauthcookie
                                     ├─► openconnect --protocol=gp --authenticate --usergroup=<gateway|portal>:prelogin-cookie  (unprivileged; prints COOKIE, CONNECT_URL, FINGERPRINT)
                                     └─► nmcli connection up GlobalProtect passwd-file=<0600 file in $XDG_RUNTIME_DIR>
```

Secrets only ever travel over stdin or that temporary file, never on a command
line, and the gateway's certificate fingerprint is pinned into the activation.
The NM profile `GlobalProtect` is a system connection (the openconnect plugin
refuses user-private ones); Omarchy's wheel polkit rule lets you manage it
without a prompt. The CLI is usable on its own:

```bash
bin/omarchy-globalprotect status              # JSON
bin/omarchy-globalprotect connect --portal vpn.example.com
bin/omarchy-globalprotect disconnect
bin/omarchy-globalprotect login       # sign in only, store the session
bin/omarchy-globalprotect forget      # drop the keyring entry and the WebKit data
bin/omarchy-globalprotect hip-report --client-os win   # what the HIP report claims (JSON)
bin/omarchy-globalprotect collect-logs                 # scrubbed troubleshooting tarball in ~/Downloads
bin/omarchy-globalprotect gateways --refresh --probe   # fetch the portal's gateway list and time each one
```

Where things live:

| What | Where |
|------|-------|
| Portal, gateway, HIP, client OS, connect method settings | this widget's entry in `~/.config/omarchy/shell.json` |
| Google session (WebKit website data) | `~/.local/share/omarchy-globalprotect/webkit/` (0700) |
| Reusable portal session cookie, remembered password | GNOME keyring, `application=omarchy-globalprotect` |
| System-browser callback handler | `~/.local/share/applications/omarchy-globalprotect-callback.desktop` |
| Tunnel DNS polkit rule (optional, installed on request) | `/etc/polkit-1/rules.d/50-omarchy-globalprotect-resolved.rules` |
| Last gateway / username / cached gateway list | `~/.local/state/omarchy-globalprotect/state.json` |
| NetworkManager profile | `nmcli connection show GlobalProtect` |

## Troubleshooting

- **A username/password prompt appears instead of Google** — the portal offered no
  SAML for the reported client OS. If it should have, try `clientOs: "linux"` or `"mac"`.
- **System browser mode never comes back** — the portal is not configured for the
  default-browser flow (it must redirect to `globalprotectcallback:`); switch back to
  the embedded window.
- **Signed in, but the tunnel fails with a HIP or "host check" message** — turn on
  *HIP report* in the panel.
- **Signed in, then "User input required in non-interactive mode"** — the gateway
  wants its own SAML sign-in. `auto` handles this; if you forced `portal`, switch
  `authInterface` to `gateway`.
- **The tunnel never comes up** — `journalctl -u NetworkManager -n 50` shows what
  openconnect said; `bin/omarchy-globalprotect connect --portal <host>` in a
  terminal prints each phase.
- **Wrong or expired session** — *Forget session* in the panel, then connect again.
- **Reporting a problem** — turn on *Debug logging* in the panel's settings, reproduce,
  then *Collect logs* (`l`). The tarball in `~/Downloads` holds the status JSON, the
  NetworkManager profile, the NetworkManager and openconnect journal, the debug log,
  and the HIP report preview, with cookies and passwords masked.

## Development

```bash
scripts/check          # py_compile + Python unit tests + Model.js tests (node) + omarchy plugin validate
```

The plugin directory is a plain git checkout; the shell hot-reloads QML on
save (run `omarchy restart shell` if a changed component type is still cached).
Design notes live in `docs/superpowers/specs/`, the build plan in `docs/superpowers/plans/`.

## License

MIT
