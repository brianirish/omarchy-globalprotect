# Omarchy GlobalProtect plugin — design

Date: 2026-09-10 · Status: implemented through v1.0.0 (decisions 19+ cover the releases after v0.1; see ROADMAP.md) (Brian gave blanket approval for decisions; every decision is logged below)

## Goal

A first-class Omarchy bar widget that connects this machine to a Palo Alto
GlobalProtect VPN using Google SSO, with the polish of the stock Tailscale
widget: a live bar icon, a keyboard-friendly panel, clean animations, and no
password prompts once set up.

Non-goals for v1: HIP spoofing beyond openconnect's stock report script,
multiple portals/profiles, gateway browsing UI (a fixed optional gateway
setting is enough), Windows/macOS.

## Decision log

| # | Decision | Why |
|---|----------|-----|
| 1 | **Login window is Python + GTK3 + WebKitGTK 4.1**, a separate process. | Quickshell crashes as soon as QtWebEngine initializes (Chromium `base::CommandLine` needs argv Quickshell never passes; verified by spike). Qt's standalone `qml` runtime renders WebEngine but cannot read HTTP response headers, which is where the portal returns `prelogin-cookie` / `portal-userauthcookie`. WebKitGTK exposes them. Everything needed (`python-gobject`, `gtk3`, `webkit2gtk-4.1`) is already installed from Arch's official repos. |
| 2 | **NetworkManager owns the tunnel** via the official `networkmanager-openconnect` plugin; no root helper, no custom polkit rule. | Brian's preference ("3 if possible"). Verified: nm-openconnect takes exactly four secrets (`cookie`, `gateway`, `gwcert`, `resolve`), which is what `openconnect --authenticate` prints, and that command runs unprivileged. `nmcli` has explicit `vpn.secrets.cookie/gateway/gwcert` support in its password file. The wheel + local polkit rule on this machine already allows `settings.modify.system` and `network-control` without a prompt. |
| 3 | Project lives at `~/.config/omarchy/plugins/brianirish.globalprotect` (a git repo) with a symlink `~/Basement/omarchy-globalprotect`. Plugin id `brianirish.globalprotect`. | Same pattern as the screensaver plugin; the plugin dir must be the checkout for `omarchy plugin` tooling and hot reload. |
| 4 | Prelogin identifies as Windows by default (`clientos=Windows`, `--os=win`), overridable via the `clientOs` setting. | Many portals reject Linux clients; gp-saml-gui defaults the same way. |
| 5 | Gateway selection is an optional text setting passed as `--authgroup`; empty means the portal's default. | A gateway picker needs an authenticated portal config fetch; keep v1 lean. |
| 6 | HIP report is a boolean setting (`hipReport`, default off) that enables openconnect's stock `hipreport.sh` via the NM profile. | Cheap to add, and it is the only fix if the portal enforces HIP. |
| 7 | Session persistence: the WebKit website-data directory persists (Google stays signed in, so re-login is a window that flashes and closes), and a reusable `portal-userauthcookie`, when the portal returns one, is stored in the GNOME keyring via `secret-tool` and tried first on the next connect. | Zero-typing reconnects are the main delight. gnome-keyring with the secrets component is running on this machine. |
| 8 | State updates come from a streaming `nmcli monitor` process plus a fallback timer (5 s open / 20 s closed) and a watchdog. | Instant reaction to NM events without hammering nmcli. |
| 9 | A Hyprland window rule is added to `~/.config/hypr/hyprland.lua` to float and center the login window (class `omarchy-globalprotect`). | Wayland apps cannot position themselves; the rule keeps the sign-in window from tiling. |
| 10 | Desktop notifications via `notify-send` on connected / disconnected / failed. | Omarchy's notification service renders them natively. |
| 11 | Tests use Python's stdlib `unittest` (pytest is not installed). QML is validated with `omarchy plugin validate` plus a live load in the shell. | No new tooling. |
| 12 | Third-party code policy: only Arch official-repo packages (`openconnect`, `networkmanager-openconnect`, and the already-installed GTK/WebKit/PyGObject stack), Qt's own `QtQuick.Shapes` for the animated ring. No AUR, no pip, no vendored JS/QML. | Brian asked for security validation of anything third-party; signed distro packages with active maintenance are the bar. |
| 13 | Settings are written by the panel through the shell's `updateEntryInline` API (like the screensaver plugin); the CLI has no `set-portal` command. Notifications are sent by `Service.qml`, not the CLI, so drops initiated by NetworkManager are announced too. | One owner per concern; the CLI stays a pure protocol tool. |
| 14 | Execution: inline in-session with one forked helper for the Python CLI (Tasks 1–5) while the QML side was written in parallel; the helper's diff was reviewed by hand instead of by separate reviewer agents. | Brian was away and gave blanket approval; parallel work shortened the wall clock. |
| 15 | The sign-in window is not embedded in the shell. The Quickshell spike crashed on `QtWebEngine` (`base::CommandLine cannot be properly initialized`), confirming decision 1. | Verified on this machine, Quickshell 0.3.1 + qt6-webengine 6.11.2. |
| 16 | **SAML happens at the gateway interface by default** (`authInterface: auto` probes `/ssl-vpn/prelogin.esp` first, then the portal), and openconnect runs with `--usergroup=gateway:prelogin-cookie`. | Verified against Brian's portal: portal login succeeded but the gateway demanded a second SAML cookie and the portal returned no reusable auth cookie (the deployment gp-saml-gui's `--gateway` flag exists for). |
| 17 | The NM profile is a **system connection** with no `connection.permissions`. | nm-openconnect refuses private connections ("The 'openconnect' plugin doesn't support private connections"); the wheel + local polkit rule makes system connections prompt-free anyway. |
| 18 | The tunnel interface is found by the VPN address (`ip -j addr`), not nmcli's `GENERAL.IP-IFACE`, which names the base device for VPNs. | Verified live: nmcli reported `enp7s0`; the tunnel is `vpn0`. |
| 19 | **Log bundle and debug log (v0.2).** `collect-logs` tars status, deps, versions, the NM profile, the NetworkManager/openconnect journals, the debug log, and the HIP preview, all through `scrub_secrets`; `--debug` appends to `$XDG_STATE_HOME/omarchy-globalprotect/debug.log` (rotated at 1 MB) and call sites never pass cookies. | Matches the official client's collect-log without ever shipping a session cookie. |
| 20 | **Gateway list comes from the portal's `getconfig.esp`** after a SAML sign-in at the portal interface (`gateways --refresh`), cached in `state.json`; refresh is explicit (panel button / `g`), latency is re-probed on every panel open. | The list needs portal auth; the persisted Google session makes the refresh a window that flashes. Verified live: portal `Client-VPN`, one gateway, HIP interval 3600, and a `portal-userauthcookie` that is now stored. |
| 21 | **Best Available = highest priority, then lowest TLS handshake latency; manual-only gateways excluded.** An explicit `gateway` setting wins. In gateway-interface mode the choice sets the host for prelogin, the sign-in window, and `openconnect`; in portal mode it is passed as `--authgroup`. The free-text field became a picker. | Mirrors the official client's selection rule; keeps one setting key. |
| 22 | **Always-On and tunnel restoration (v0.4) are one pure decision** (`Model.autoConnectDecision`) fed by NetworkManager's connectivity state from `status`: connect when idle and online, wait on captive portal (notify once) or offline, back off 30 s → 10 min on failures, and never while paused or while the user is switching off. A user disconnect or a cancelled sign-in pauses Always-On for `pauseMinutes`. A tunnel that drops without a user action is restored in both modes. Model.js is now unit-tested with Node (`tests/model_test.js`), skipped by `scripts/check` when Node is absent. | The rule set is easy to get subtly wrong (retry loops, fighting the user); a pure function with tests keeps the service a thin loop. Node is present on this machine via mise and is optional. |
| 23 | **Sign-in options (v0.5).** Prelogin without SAML yields a `PASSWORD` form (auto mode still prefers an interface that offers SAML); credentials come from a themed GTK dialog with the portal's labels or from the keyring (*Remember*). Password logins drive `openconnect` through a pty so any further prompt (OTP, push, challenge) opens a dialog. `--browser` uses the default browser with a `globalprotectcallback:` handler registered in `~/.local/share/applications`, only when prelogin advertises `saml-default-browser`. Proxy and client certificate flow into urllib, openconnect, and the NM profile. | Covers LDAP/RADIUS portals and MFA without reimplementing the login protocol. Verified live: the portal advertises the default-browser flow and the redirect opens; the return trip needs Firefox's one-time "open link" confirmation, so it is not autonomously verifiable. |
| 24 | **Tunnel DNS goes through systemd-resolved per link (v0.6).** Omarchy pins DNS with NetworkManager's `[global-dns-domain-*]`, which discards every connection's DNS (and `resolve-mode` only applies to the dnsconfd plugin), so after activation the CLI runs `resolvectl dns/domain/default-route` on the tunnel link. resolved's polkit actions are `auth_admin_keep`, so a one-time `pkexec` installs `50-omarchy-globalprotect-resolved.rules` (wheel + local session, four resolve1 actions). `dnsMode` auto/split/off. SSL-only and MTU use the plugin's `disable_udp`/`mtu` keys; "no local network" routes the physical LAN subnets (`ip -j route`, kernel on-link, virtual devices excluded) into the tunnel via `ipv4.routes`. | Without it internal hostnames never resolve on Omarchy. The rule is the narrowest thing that works; it is optional and only offered when the global pin is detected. |
| 25 | **Portal-driven behaviour (v0.7).** The gateway refresh parses `agent-config`/`agent-ui` into a policy (connect method, MTU, SSL-only, rediscover/sign-out permissions, welcome page, refresh interval, HIP interval); with `followPortal` (default on) the panel writes connect method, MTU, and SSL-only into its settings, mirroring the official client. Config refresh on the portal's interval is attempted silently with the stored `portal-userauthcookie` (`--quiet`, at most hourly) and otherwise waits for a user-driven refresh. State is per portal (`portals/<host>.json`, migrated from the flat file on first read) so several portals can coexist. HIP notifications come from openconnect's journal lines. | Parity with the official client's portal-controlled settings without a daemon. Verified live: `connect-method=user-logon`, `tunnel-mtu=1400`, refresh 24 h; this portal answers HTTP 512 to the cookie-based config request, so silent refresh falls back gracefully. |
| 26 | **v1.0 = parity with the official Linux app's user-facing set.** Every setting has a panel control (the last four, client OS, sign-in interface, refresh and pause intervals, became toggles and numeric fields), the portal-facing CLI paths are covered by tests through a fake urllib opener and a fake `run`, and the README is organised around a settings reference. The hard tier (domain split tunnel, traffic enforcement, kill switch, internal host detection) stays beyond 1.0 by Brian's choice. | The roadmap's definition of done; nothing user-facing is left that needs `shell.json` by hand. |

## Architecture

```
┌──────────────── omarchy-shell (Quickshell) ────────────────┐
│ Panel.qml ── Service.qml ──► bin/omarchy-globalprotect ────┼──► nmcli / NetworkManager ──► nm-openconnect ──► openconnect (root, NM-supervised)
│  bar icon    state machine     status --json / connect /    │        ▲
│  hero/rows   nmcli monitor     disconnect / forget ...      │        │ vpn.secrets.{cookie,gateway,gwcert,resolve}
└─────────────────────────────────────────────────────────────┘        │
                                                                        │
                        bin/omarchy-globalprotect connect ──► prelogin.esp (HTTPS POST) ──► SAML method + request
                                    │                                                       │
                                    ├──► gp_login window (GTK3 + WebKitGTK) — Google SSO ───┘ → prelogin-cookie / portal-userauthcookie / saml-username
                                    ├──► openconnect --authenticate --usergroup=portal:<cookie-kind> --passwd-on-stdin (unprivileged)
                                    └──► nmcli connection up GlobalProtect passwd-file=<0600 tmp in $XDG_RUNTIME_DIR>
```

### Components

1. `manifest.json` — `kinds: ["bar-widget"]`, entry `Panel.qml`, settings with schema:
   `portal` (string), `gateway` (string, optional), `clientOs` (win|linux|mac, default win),
   `hipReport` (bool, default false), `refreshIntervalSec` (int, default 5).
2. `Panel.qml` — bar button + `KeyboardPanel`. Owns UI state only.
3. `Service.qml` — instantiated inside the panel (like Tailscale). Owns process
   plumbing and the state machine; exposes plain properties to the panel.
4. `GpIcon.qml` — natively drawn shield mark with an animated ring
   (`QtQuick.Shapes`), used at bar size and hero size.
5. `Model.js` — pure functions: status parsing, byte/duration formatting,
   phrase list, sparkline sampling.
6. `bin/omarchy-globalprotect` — Python 3 CLI (single file, stdlib + `gi`).
   Subcommands below. Contains the SSO window code (GTK), launched in-process.
7. `bin/omarchy-globalprotect-install-deps` — tiny wrapper that runs
   `pkexec pacman -S --needed --noconfirm networkmanager-openconnect`.
8. `tests/test_cli.py` — unit tests for every pure function in the CLI.
9. `scripts/check` — runs unit tests, `python -m py_compile`, `omarchy plugin validate .`.

### CLI contract (`bin/omarchy-globalprotect`)

| Command | Behaviour | Exit |
|---------|-----------|------|
| `status [--json]` | Prints state JSON (schema below). Never blocks on network. | 0 |
| `connect [--portal H] [--gateway G] [--client-os win\|linux\|mac] [--hip] [--fresh]` | Full flow: ensure NM profile → obtain session (keyring cookie first, else SSO window) → `openconnect --authenticate` → `nmcli connection up`. Streams `phase=<name>` lines on stdout: `preparing`, `signing-in`, `authenticating`, `activating`, `connected`. Errors go to stderr as `error=<message>`. `--fresh` skips the stored cookie. | 0 ok, 2 user cancelled, 1 error, 3 missing deps |
| `disconnect` | `nmcli connection down GlobalProtect` | 0 / 1 |
| `login` | Runs only the SSO window and stores the resulting cookie (no tunnel). | as connect |
| `forget` | Deletes keyring entries and the WebKit website-data directory. | 0 |
| `deps` | Prints `{"openconnect":bool,"nmOpenconnect":bool,"webkit":bool}` | 0 |

Status JSON:

```json
{
  "state": "unconfigured|missing-deps|disconnected|authenticating|activating|connected|error",
  "portal": "vpn.example.com",
  "gateway": "gw1.example.com",     // from the active NM secrets' connect URL host, or last known
  "iface": "vpn0", "ip4": "10.1.2.3",
  "since": 1757490000,               // NM connection.timestamp (seconds) while connected
  "rxBytes": 0, "txBytes": 0,        // /sys/class/net/<iface>/statistics
  "username": "brian@company.com",   // saml-username from last login, if any
  "hasSession": true,                // a portal cookie is stored in the keyring
  "detail": "human readable line",
  "deps": {"openconnect": true, "nmOpenconnect": true, "webkit": true}
}
```

`authenticating`/`activating` are derived from a run file
`$XDG_RUNTIME_DIR/omarchy-globalprotect/connect.json` (`{"pid":…, "phase":…}`)
written by `connect`, so the panel state survives a shell hot-reload; a dead
pid means the run file is stale and is ignored.

### NetworkManager profile

Created/updated idempotently by `connect` (name `GlobalProtect`):

```
nmcli connection add type vpn con-name GlobalProtect ifname '*' vpn-type openconnect \
  connection.permissions "user:$USER" \
  vpn.data "gateway=<portal>,protocol=gp,authtype=password,cookie-flags=2,gateway-flags=2,gwcert-flags=2,resolve-flags=2,enable_csd_trojan=<yes|no>[,csd_wrapper=/usr/lib/openconnect/hipreport.sh]"
```

Secret flags `2` (not saved) make NM ask its agent each activation; `nmcli … up passwd-file=` is that agent. The password file holds
`vpn.secrets.cookie`, `vpn.secrets.gateway` (connect URL), `vpn.secrets.gwcert` (pinned cert hash), `vpn.secrets.resolve` (if printed), is created 0600 in `$XDG_RUNTIME_DIR`, and is deleted in a `finally`.

### SSO flow details (mirrors gp-saml-gui, the proven reference)

1. `POST https://<portal>/global-protect/prelogin.esp` with
   `tmp=tmp&kerberos-support=yes&ipv6-support=yes&clientVer=4100&clientos=<ClientOS>`; TLS verified with system CAs.
2. Parse `<saml-auth-method>` (`POST` or `REDIRECT`) and base64 `<saml-request>`. A `<status>Error</status>` with `<msg>` becomes the error text.
3. GTK window (`app_id` `omarchy-globalprotect`, 480×720, theme colors from `~/.local/state/omarchy/current/theme/colors.toml`): a slim header "Signing in to <portal>", a pulsing progress bar while loading, WebKit view below. `REDIRECT` → `load_uri`; `POST` → `load_html(saml_request, https://<portal>/)`.
4. On every finished resource load, inspect response headers; on every `load-changed FINISHED`, read `document.documentElement.outerHTML` and regex `<saml-auth-status>`, `<prelogin-cookie>`, `<portal-userauthcookie>`, `<saml-username>` out of HTML comments. Success = `saml-username` plus one of the cookies. Show "Signed in as …" for 600 ms, then close.
5. `openconnect --protocol=gp --authenticate --non-inter --os=<os> --user=<saml-username> --usergroup=portal:<cookie-kind> --passwd-on-stdin [--authgroup=<gateway>] [--csd-wrapper …] <portal>` with the cookie on stdin. Parse `COOKIE`, `HOST`, `CONNECT_URL`, `FINGERPRINT`, `RESOLVE` with `shlex`.
6. If a `portal-userauthcookie` was obtained, store it (and the username) with `secret-tool` under `application=omarchy-globalprotect portal=<host> kind=<name>`. Next `connect` tries it first via `--usergroup=portal:portal-userauthcookie`; on failure it falls back to the window transparently.

Timeouts: window 5 min, authenticate 60 s, `nmcli up --wait 60`.

## Panel UI

States: `unconfigured`, `missing-deps`, `disconnected`, `authenticating` (window open), `activating` (NM bringing the tunnel up), `connected`, `error`.

Layout top → bottom (width `Style.space(380)`):

1. **Hero** (`PanelHero`): `GpIcon` (display size) · title "GlobalProtect" · meta line (state text; when connected, rotating phrases every 2.8 s with the Tailscale fade swap) · `ToggleSwitch` trailing (optimistic, `busy` during transitions).
2. **Status line**: action progress or error (urgent color), fades in 180 ms.
3. **SESSION** (connected only): rows Gateway · Address (click/`c` copies) · Connected for (ticks each second) · Throughput: live sparkline (Canvas, last 40 samples, 300 ms eased) with "↓ 1.2 MB/s ↑ 80 KB/s".
4. **ACCOUNT** (when a username or stored session exists): "Signed in as …" · buttons *Sign in again* (`s`) and *Forget session* (`f`, with `ConfirmDialog`).
5. **SETUP** (unconfigured): `TextField` for portal host + *Save* (Enter). Caption explains Google SSO opens in its own window.
6. **INSTALL** (missing deps): explains and offers *Install* → runs the install-deps wrapper (polkit prompt).
7. **SETTINGS** (always, collapsed under a section header): Gateway text field, HIP report `Toggle`.

Bar icon: `GpIcon` at bar size; dimmed when off; 420 ms opacity pulse while authenticating/activating; small urgent dot on error; tooltip = state text. Left click opens the panel, right click toggles the connection, middle click refreshes.

Animations (all within the shell's vocabulary, 120–420 ms, OutCubic/InOutCubic):
- Icon ring: while connecting, a 90° arc orbits (1.1 s loop); on connected the arc grows to a full ring over 360 ms and settles at 0.35 opacity; on disconnect it fades out 240 ms.
- Section show/hide: opacity + height behaviors, 160 ms.
- Colors: `Behavior on color` 160 ms everywhere the state colors a glyph.
- Sparkline: displayed values ease over 300 ms; new samples slide in.

Keyboard: `j/k` or arrows move the cursor over actionable rows; `Enter`/`Space` activates; `t` toggles; `r` refreshes; `c` copies the address; `s` signs in again; `f` forgets the session; `Esc` closes; `Tab` switches panels.

## Error handling

- CLI: every external step has a timeout; failures produce one `error=` line with a human message (never a cookie); exit codes as above. Stale run files are ignored by pid check. Password file always removed.
- Service: process exit codes map to `error` state with `detail`; `nmcli monitor` restarts itself if it exits; watchdog kills a stuck status poll after 15 s; optimistic toggle state resets when reality disagrees.
- Panel: error text shown inline and in a notification; the toggle stays usable for retry.

## Security notes

- Secrets only travel over stdin or a 0600 file in `$XDG_RUNTIME_DIR`, never argv. Logs and `phase=` output never include cookies.
- The gateway certificate fingerprint from `--authenticate` is pinned into the NM activation (`--servercert`).
- Prelogin uses TLS verification. WebKit uses default TLS policy (errors are shown, not bypassed).
- WebKit website data lives in `~/.local/share/omarchy-globalprotect/webkit` (0700). *Forget session* wipes it and the keyring entries.
- One system NM profile (`GlobalProtect`) is created; nothing is installed outside the plugin dir except the optional pacman install through pkexec.

## Testing

- `tests/test_cli.py` (unittest): prelogin XML parsing (POST/REDIRECT/error), SAML result extraction from headers and HTML comments, `--authenticate` output parsing (quoted values, missing RESOLVE), password-file rendering, NM `vpn.data` string building, nmcli status parsing → state JSON, run-file staleness, byte/duration formatting helpers if they live in Python.
- `Model.js` logic is kept pure so it can be exercised by loading in the panel; the panel itself is verified live (`omarchy plugin validate`, enable, open, screenshot).
- Real-portal verification is a manual step (needs Brian's portal hostname): documented in README as the first-run checklist.

## Install / onboarding

1. `omarchy plugin add <repo> --enable` (or it is already in place locally).
2. Open the panel → *Install* (if `networkmanager-openconnect` is missing) → enter portal → toggle on → Google window → connected.
3. Optional: `ln -s ~/.config/omarchy/plugins/brianirish.globalprotect/bin/omarchy-globalprotect ~/.local/bin/` for terminal use.

## Open items to verify against the real portal

- ~~Whether the portal returns `portal-userauthcookie`~~ Verified: it does not; sign-in happens at the gateway and relies on Google's persisted session for silent reconnects.
- HIP: the portal advertises a 60-minute HIP interval; Brian runs with the HIP setting on and the tunnel came up.
- Whether the portal accepts `clientos=Linux`; if so flip `clientOs` to `linux` for honesty.
