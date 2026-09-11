# Changelog

## 1.0.1 — 2026-09-11

- Fix: the widget failed to load on a cold shell start (login or `omarchy restart shell`)
  with `Panel.qml:1106: Cannot override FINAL property`, so the bar showed nothing. The
  settings field's `activeFocus` alias shadowed Item's FINAL property; hot reload had
  accepted it, which is how it shipped. Renamed to `editing`.
- `scripts/check` now lints the QML with `qmllint` and fails on anything the shell
  would refuse to load.

## 1.0.0 — 2026-09-10

- Every setting is now editable in the panel: *Reports as* (client OS), *Sign-in
  interface*, *Refresh (s)*, and *Pause (min)* join the rest; no more `shell.json`
  hand edits.
- First-run copy explains what happens after the portal is saved.
- Coverage for the CLI paths that talk to the portal: prelogin and the config fetch
  (request body, headers, error mapping), the password-file lifecycle around
  `nmcli connection up`, split-DNS application, and latency probing.
- README rewritten around the full feature set, with a settings reference and a CLI
  reference.

## 0.7.0 — 2026-09-10

- Portal-driven app settings: the gateway refresh also parses `agent-config` (connect
  method, tunnel MTU, SSL-only, rediscover/sign-out permissions, welcome page, refresh
  interval) and, with *Follow the portal's settings* on, applies connect method, MTU,
  and SSL-only. The config is refreshed silently on the portal's interval via the
  stored portal cookie (`gateways --refresh --quiet`).
- Multiple portals: state is now per portal (`portals/<host>.json`); a *Portals*
  section lists known portals with click-to-switch; `forget --remove` drops one.
- HIP notifications: `hip-status` reads the last check/submission from openconnect's
  journal; the panel shows it under *Host state* and raises warnings as notifications.
- Welcome page: `welcome --show` opens the portal's page; `w` in the panel.

## 0.6.0 — 2026-09-10

- Tunnel DNS (`dnsMode`): the gateway's DNS servers and search domains are applied to
  the tunnel link in systemd-resolved after activation, which Omarchy's global DNS pin
  otherwise discards. Needs a one-time polkit rule (*Enable tunnel DNS* button, `pkexec`).
  `auto` routes pushed domains (all queries on a full tunnel without domains), `split`
  routes pushed domains only, `off` does nothing. The DNS row shows what is in effect.
- SSL only (`sslOnly`, `disable_udp`), MTU override (`mtu`), and No direct access to
  local network (`blockLan`: LAN subnets routed into the tunnel via `ipv4.routes`).
- IPv6: `status` reports the tunnel's global IPv6 address; the Address row shows it.

## 0.5.0 — 2026-09-10

- Username/password portals (LDAP/RADIUS): when prelogin offers no SAML, a themed
  credentials dialog uses the portal's own labels; *Remember* keeps the password in the
  GNOME keyring. openconnect is driven through a pty, so any further prompt it relays
  (one-time code, push approval, challenge) opens a dialog instead of failing.
- System browser for SAML (`samlBrowser: system`, `--browser`): opens the sign-in in the
  default browser, registers a `globalprotectcallback:` scheme handler, and waits for the
  portal's callback (CAS `un`/`token` or base64 HTML).
- Client certificate (`certificate`, `certificateKey`, `--certificate`, `--key`) for
  prelogin, config fetch, openconnect, and the NM profile.
- Proxy (`proxy`, `--proxy`) for prelogin, config fetch, openconnect, and the NM profile.
- Settings gains text fields for proxy, certificate, and key, and a system-browser toggle.

## 0.4.0 — 2026-09-10

- *Always-On* connect method (`connectMethod: always-on`): connects when the shell
  starts and whenever NetworkManager reports full connectivity again; failures back off
  30 s → 10 min; a captive portal is announced instead of attempted; flipping the switch
  off or cancelling the sign-in pauses it for `pauseMinutes` (default 30, `p` to resume).
- Tunnel restoration in both modes: a tunnel that drops without you asking is
  reconnected, with a fresh sign-in if the session expired.
- `status` reports NetworkManager's `connectivity` (full, limited, portal, none).
- Model.js now has unit tests (`node tests/model_test.js`, run by `scripts/check` when
  Node is installed).

## 0.3.0 — 2026-09-10

- *Gateways* section: fetch the portal's gateway list (`gateways --refresh`, `g` key),
  see priority and TLS latency for each, and click one to prefer it. *Best available*
  (empty `gateway` setting) picks the highest priority, then the lowest latency, like
  the official client. Manual-only gateways are never auto-picked.
- With the gateway sign-in interface, the SAML sign-in and `openconnect` now target the
  chosen gateway's host; with the portal interface the choice is passed as `--authgroup`.
- The free-text gateway field in Settings is replaced by the picker (the `gateway`
  setting key is unchanged and still accepts a name by hand in `shell.json`).

## 0.2.0 — 2026-09-10

- The NetworkManager profile is persistent (`vpn.persistent yes`): link changes and
  resume from suspend no longer tear the tunnel down; openconnect reconnects with the
  same session.
- *Rediscover network* (`n` key, panel button, `rediscover` IPC): drop the tunnel and
  reconnect through the stored session.
- Connection details in the panel and in `status --json`: tunnel protocol (ESP over
  UDP or SSL, detected from the socket to the gateway), gateway IP, pushed routes
  (full or split), DNS servers and search domains.
- *Host state* section in the panel and a `hip-report` CLI command: what the HIP
  report claims about this machine (OS and client version, host name and ID, and any
  security products the stock script lists).
- *Collect logs* (`l` key, panel button, `collect-logs` CLI): a 0600 tarball in
  `~/Downloads` with status, profile, journals, debug log, and HIP preview; cookies and
  passwords are masked.
- *Debug logging* setting (`debug` in `shell.json`, `--debug` on the CLI): each connect
  step is appended to `~/.local/state/omarchy-globalprotect/debug.log` (rotated at 1 MB).

## 0.1.0 — 2026-09-10

Initial release.

- Bar widget + panel: connection switch, gateway, address (copy), time connected, throughput sparkline.
- Google SSO through a themed GTK/WebKitGTK window; Google session persists between connects.
- Reusable portal session cookie stored in the GNOME keyring when the portal provides one.
- NetworkManager owns the tunnel via `networkmanager-openconnect`; secrets passed through a 0600 password file.
- Optional HIP report and gateway selection; reported client OS setting.
- SAML sign-in at the gateway interface by default (`authInterface: auto`), for deployments whose gateway demands its own SSO; portal mode remains available.
- Keyboard navigation, desktop notifications, one-click dependency install.
