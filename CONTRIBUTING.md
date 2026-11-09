# Contributing

Thanks for helping improve the Omarchy GlobalProtect widget!

## Development setup

The plugin is developed in place. Clone it where Omarchy loads plugins from:

```bash
git clone https://github.com/brianirish/omarchy-globalprotect.git \
  ~/.config/omarchy/plugins/brianirish.globalprotect
omarchy-shell shell rescanPlugins
omarchy plugin enable brianirish.globalprotect
```

(If you installed it with `omarchy plugin add`, that directory is already a git
checkout: fork, add your remote, and work there.)

If the machine's own VPN depends on this plugin, work in a second clone
somewhere else and run `scripts/check` there; switch the live checkout only to
try a finished change.

## Layout

- `Panel.qml` is the bar icon and the panel, `Service.qml` the headless state
  machine that runs every process, and `GpIcon.qml` the shield.
- `Model.js` holds the pure logic. Keep it free of QML imports so
  `node tests/model_test.js` keeps running, and add a test there for every
  behaviour change.
- `bin/omarchy-globalprotect` is the Python CLI (standard library, plus
  PyGObject only for the sign-in windows). Its pure helpers are tested in
  `tests/test_cli.py`; add a test there for every CLI change.

## Iterating

- Saving files under `~/.config/omarchy/plugins/` triggers the shell's
  hot-reload, **but** the QML engine can keep serving a cached component even
  after `rescanPlugins`. When a change doesn't show up, run
  `omarchy restart shell`; that always picks it up.
- Watch for QML errors and the widget's decisions with
  `journalctl --user -f | grep -i -e qml -e gp-trace`.
- Style: follow the stock panels in `/usr/share/omarchy/shell/plugins/`
  (the Tailscale panel was this one's template). Use the
  `qs.Ui` kit and the `Style`/`Color` tokens rather than hardcoded values so
  themes keep working, `Style.duration()` for every animation, and
  `textFormat: Text.PlainText` on every `Text`: portal names, gateway names
  and error messages come from the network.
- Run `scripts/check` before opening a PR. It is exactly what CI runs.

## Adding or changing a string

Everything the panel, the bar tooltip and the notifications say comes from
`i18n/en.json`, read through `Commons.Translations`. To add a string:

1. Add the key and its English text to `i18n/en.json`. Translators see only
   the key and the English, so make the text clear on its own, and use `%1`,
   `%2` for values rather than gluing pieces together. A string that counts
   something is a plural entry: `{"one": "%1 gateway", "other": "%1 gateways"}`.
2. Use it through `strings.t("key")` (or `strings.tn("key", count)`) in
   `Panel.qml`, `tr.t(...)` in `Service.qml`, and the `tr` argument in
   `Model.js`. Write each key out in full: `tests/i18n_test.js` finds keys by
   their literal text, so a key built at runtime (`t("state." + s)`) fails the
   check. Fill placeholders with `Model.fill()`, and write numbers with
   `I18n.formatNumber()` (Model.js takes it as `formatNumber`).
3. Keep data as data: portal hosts, gateway names, usernames, addresses and
   DNS entries go into placeholders verbatim, never into the catalog.
4. Run `scripts/check`. It fails on a key the code uses that `en.json` lacks,
   and on an `en.json` key nothing uses.

The other languages are machine-translated, so a new string may lag behind
in them for a while and falls back to English until it is translated.
Corrections to a translation are welcome as a PR that edits
`i18n/<code>.json`. The CLI's own messages (the sign-in windows and the
errors it prints) are English for now.

## Releasing

Before tagging a release, run `I18N_STRICT=1 scripts/check`. It also fails
when any Omarchy language is missing a catalog or a string.

## Testing without a VPN

`scripts/check` needs no portal, gateway or NetworkManager: the CLI tests mock
the network and use a fake `openconnect`, and `Model.js` takes plain objects.
Don't add tests that reach a real portal or change NetworkManager state.

## Pull requests

- One logical change per PR.
- Update `CHANGELOG.md` under the `Unreleased` heading.
- Include a screenshot for visual changes (`omarchy capture screenshot`),
  with your portal's name and your username cropped or blurred.
- Note the Omarchy version you tested on, and how your portal signs you in
  (SAML in the window, system browser, password, certificate).

## Bugs and ideas

Open an issue using the templates, and redact portal hostnames, usernames,
addresses and DNS names from anything you paste. For security problems, see
[SECURITY.md](SECURITY.md); please don't open public issues for those.
