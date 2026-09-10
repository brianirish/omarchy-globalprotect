# Changelog

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
