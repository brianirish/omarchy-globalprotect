# Security Policy

This plugin handles VPN sign-ins, session cookies and, if you ask it to,
passwords, so security reports are especially welcome.

## Supported versions

Only the latest release on `main` is supported. Omarchy plugins are installed
as git checkouts and updated with `omarchy plugin update`, so staying current
is one command.

## Reporting a vulnerability

Please **do not** open a public issue for security problems. Instead, use
GitHub's private vulnerability reporting:

**[Report a vulnerability](https://github.com/brianirish/omarchy-globalprotect/security/advisories/new)**

If that page isn't available to you, email **irishb@gmail.com** with
"omarchy-globalprotect security" in the subject.

You should get a response within a week. Please include reproduction steps,
the Omarchy version (`omarchy version`) and the plugin commit
(`git -C ~/.config/omarchy/plugins/brianirish.globalprotect log -1 --oneline`).
Leave out your real portal hostname, username and any cookies; a placeholder
such as `vpn.example.com` is enough.

## Threat model notes

Useful context for assessing findings:

- Omarchy shell plugins run **unsandboxed** inside `omarchy-shell` as the
  logged-in user. This is true of every plugin, and `omarchy plugin add`
  warns about it.
- The widget (`Panel.qml`, `Service.qml`) runs only the plugin's own CLI
  (`bin/omarchy-globalprotect`), `nmcli monitor`, `notify-send` and
  `wl-copy`, each with an argument list rather than a shell string; the one
  value it hands to `bash -c` (an address or a log path for `wl-copy`) is
  quoted with Omarchy's `Util.shellQuote`. Text from the portal, the gateway
  and NetworkManager is shown through plain-text elements only.
- The CLI talks over HTTPS to the portal and gateways **you configure**:
  prelogin, the portal config, and the gateway list. Portal and gateway
  certificates are verified by Python and openconnect; the gateway's
  fingerprint is pinned into the NetworkManager activation. The gateway
  latency probe skips certificate checks because it only times the TLS
  handshake and sends nothing.
- The sign-in window is WebKitGTK showing your identity provider's pages, with
  its own website data in `~/.local/share/omarchy-globalprotect/webkit/`
  (mode 0700) so Google stays signed in. The portal's welcome page is shown
  in the same kind of window.
- Secrets travel over stdin or a mode 0600 file in `$XDG_RUNTIME_DIR`, never
  on a command line. The portal session cookie and any remembered password
  live in the GNOME keyring (`application=omarchy-globalprotect`). The debug
  log and the *Collect logs* bundle mask cookies and passwords.
- Root is needed twice, both times through a polkit prompt you trigger:
  installing `networkmanager-openconnect` with pacman, and, optionally,
  installing `/etc/polkit-1/rules.d/50-omarchy-globalprotect-resolved.rules`,
  which lets local `wheel` users set link DNS in systemd-resolved without a
  prompt (so the tunnel's DNS can be applied).
- The NetworkManager profile `GlobalProtect` is a system connection, because
  the openconnect plugin refuses user-private ones.
