# Omarchy GlobalProtect

A native [Omarchy](https://omarchy.org) bar widget for Palo Alto GlobalProtect
VPNs that use Google (SAML) single sign-on. One switch in the bar, a themed
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
| Reusable portal session cookie | GNOME keyring, `application=omarchy-globalprotect` |
| Last gateway / username / cached gateway list | `~/.local/state/omarchy-globalprotect/state.json` |
| NetworkManager profile | `nmcli connection show GlobalProtect` |

## Troubleshooting

- **"Portal did not offer SAML login"** — the portal is not configured for SSO
  with the reported client OS. Try `clientOs: "linux"` or `"mac"` in `shell.json`.
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
