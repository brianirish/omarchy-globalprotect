# Vendored upstream tools

Verbatim copies of files from [basecamp/omarchy](https://github.com/basecamp/omarchy),
used by `scripts/check` and the tests. They are unmodified so refreshing one
is a plain download. Each was taken at the Omarchy release tag the plugin
supports; the commit column is that tag's revision, or for a file that has not
changed since an earlier release, the revision that last changed it.

| File | Upstream path | Taken at | Commit |
|------|---------------|----------|--------|
| `omarchy-plugin-validate` | `bin/omarchy-plugin-validate` | `v4.5.0` | `ac2690c` |
| `Plural.js` | `shell/Commons/Plural.js` | `v4.5.0` | `ac2690c` |
| `locales.json` | `default/i18n/locales.json` | `v4.5.0` | `ac2690c` |
| `qml-text-format-scan.py` | `test/shell.d/qml-text-format-scan.py` | `v4.5.0` | `4be440b` (unchanged at `v4.5.0`) |

`Plural.js` and `locales.json` let `tests/tr.js` and `tests/i18n_test.js` pick
plural forms and list languages exactly as the shell does.

Refresh, pinned to a release tag rather than a moving branch:

```bash
tag=v4.5.0
base=https://raw.githubusercontent.com/basecamp/omarchy/$tag
curl -fsSL -o scripts/vendor/omarchy-plugin-validate "$base/bin/omarchy-plugin-validate"
curl -fsSL -o scripts/vendor/Plural.js "$base/shell/Commons/Plural.js"
curl -fsSL -o scripts/vendor/locales.json "$base/default/i18n/locales.json"
curl -fsSL -o scripts/vendor/qml-text-format-scan.py "$base/test/shell.d/qml-text-format-scan.py"
```

Then update the table and run `scripts/check`.
