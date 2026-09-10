# GlobalProtect Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An Omarchy bar widget + panel that connects to a GlobalProtect VPN through Google SSO, with NetworkManager owning the tunnel.

**Architecture:** A Python CLI (`bin/omarchy-globalprotect`) does all the protocol work: prelogin, a GTK/WebKit sign-in window, an unprivileged `openconnect --authenticate`, and `nmcli connection up` with a password file. A Quickshell plugin (`Panel.qml` + `Service.qml`) drives that CLI, streams NetworkManager events, and renders the bar icon and panel.

**Tech Stack:** Python 3.14 stdlib + PyGObject (GTK 3, WebKit2GTK 4.1, Soup 3), openconnect 9.21, networkmanager-openconnect 1.2.10, Quickshell 0.3.1 QML with Omarchy's `qs.Ui`/`qs.Commons` kit and `QtQuick.Shapes`.

**Spec:** `docs/superpowers/specs/2026-09-10-globalprotect-plugin-design.md`

## Global Constraints

- Only Arch official-repo packages; no AUR, no pip, no vendored code (spec decision 12).
- Secrets never appear in argv, logs, or `phase=` output; password file is 0600 in `$XDG_RUNTIME_DIR` and always deleted.
- Plugin id `brianirish.globalprotect`; NM connection name `GlobalProtect`; login window app id `omarchy-globalprotect`.
- Animations use the shell's vocabulary: 120–420 ms, `Easing.OutCubic` / `Easing.InOutCubic`.
- Tests: `python -m unittest discover -s tests` (no pytest on this machine).
- Commit after every task; `scripts/check` must pass before a commit.

---

## File structure

| File | Responsibility |
|------|----------------|
| `manifest.json` | Plugin identity, settings defaults + schema |
| `bin/omarchy-globalprotect` | Python CLI: pure helpers (top of file), SSO window, NM/keyring plumbing, subcommands |
| `bin/omarchy-globalprotect-install-deps` | `pkexec pacman -S --needed --noconfirm networkmanager-openconnect` |
| `tests/test_cli.py` | Unit tests for every pure helper in the CLI |
| `scripts/check` | py_compile + unittest + `omarchy plugin validate` |
| `Model.js` | Pure QML-side helpers: status normalisation, formatting, phrases, sparkline sampling |
| `GpIcon.qml` | Natively drawn shield + animated ring |
| `Service.qml` | Process plumbing + state machine, exposes plain properties |
| `Panel.qml` | Bar button, panel layout, keyboard cursor |
| `README.md`, `LICENSE`, `CHANGELOG.md`, `.gitignore` | Project docs |

---

### Task 1: Scaffold and manifest

**Files:**
- Create: `manifest.json`, `LICENSE` (MIT), `.gitignore`, `scripts/check`, `bin/omarchy-globalprotect-install-deps`

**Produces:** settings keys `portal`, `gateway`, `clientOs`, `hipReport`, `refreshIntervalSec` read by Service.qml.

- [ ] **Step 1: Write manifest.json**

```json
{
  "schemaVersion": 1,
  "id": "brianirish.globalprotect",
  "name": "GlobalProtect",
  "version": "0.1.0",
  "author": "Brian",
  "license": "MIT",
  "description": "GlobalProtect VPN with Google SSO: connect, watch, and manage the tunnel from the Omarchy bar.",
  "kinds": ["bar-widget"],
  "entryPoints": { "barWidget": "Panel.qml" },
  "barWidget": {
    "displayName": "GlobalProtect",
    "description": "Connect to a GlobalProtect VPN through Google SSO. NetworkManager owns the tunnel.",
    "category": "Network",
    "allowMultiple": false,
    "defaultSection": "right",
    "defaults": { "portal": "", "gateway": "", "clientOs": "win", "hipReport": false, "refreshIntervalSec": 5 },
    "schema": [
      { "key": "portal", "type": "string", "label": "Portal host" },
      { "key": "gateway", "type": "string", "label": "Gateway (optional)" },
      { "key": "clientOs", "type": "string", "label": "Reported client OS (win, linux, mac)" },
      { "key": "hipReport", "type": "boolean", "label": "Submit HIP report" },
      { "key": "refreshIntervalSec", "type": "integer", "label": "Refresh interval (seconds)", "min": 2, "max": 120, "step": 1, "defaultValue": 5 }
    ]
  }
}
```

- [ ] **Step 2: Write scripts/check**

```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -m py_compile bin/omarchy-globalprotect
python3 -m unittest discover -s tests -v
if command -v omarchy >/dev/null; then omarchy plugin validate . ; fi
echo "check: ok"
```

- [ ] **Step 3: Write bin/omarchy-globalprotect-install-deps**

```bash
#!/usr/bin/env bash
# Installs the NetworkManager OpenConnect plugin (pulls openconnect) via polkit.
set -euo pipefail
exec pkexec pacman -S --needed --noconfirm networkmanager-openconnect
```

- [ ] **Step 4: Validate** — Run `omarchy plugin validate ~/.config/omarchy/plugins/brianirish.globalprotect`; expected: manifest accepted (an entry point file missing is acceptable at this point only if the validator allows it; otherwise add a placeholder `Panel.qml` containing an empty `Item {}` and replace it in Task 8).
- [ ] **Step 5: Commit** `chore: scaffold plugin manifest and check script`

---

### Task 2: CLI pure helpers (TDD)

**Files:**
- Create: `bin/omarchy-globalprotect` (top section), `tests/test_cli.py`

**Produces (module-level functions, all pure):**
- `parse_prelogin(xml_text: str) -> dict` → `{"method": "POST"|"REDIRECT", "request": str}`; raises `PreloginError(msg)`
- `extract_saml_result(headers: dict|None, html: str|None) -> dict` keys among `saml-username`, `prelogin-cookie`, `portal-userauthcookie`, `saml-auth-status`
- `saml_result_complete(result: dict) -> bool`
- `choose_cookie(result: dict) -> tuple[str, str]` → `(kind, value)`, prefers `prelogin-cookie`
- `parse_authenticate_output(text: str) -> dict` keys `COOKIE HOST CONNECT_URL FINGERPRINT RESOLVE`
- `render_passwd_file(auth: dict) -> str`
- `build_vpn_data(portal: str, hip: bool, hip_script: str|None) -> str`
- `parse_nmcli_terse(text: str) -> dict` (handles `\:` escapes)
- `derive_state(conn_state: str|None, runfile: dict|None, portal: str, deps: dict) -> str`

Tests import the CLI by path:

```python
import importlib.util, pathlib, unittest
CLI = pathlib.Path(__file__).resolve().parents[1] / "bin" / "omarchy-globalprotect"
spec = importlib.util.spec_from_file_location("gpcli", CLI)
gp = importlib.util.module_from_spec(spec); spec.loader.exec_module(gp)
```

- [ ] **Step 1: Write failing tests**

```python
class PreloginTests(unittest.TestCase):
    def test_post_method_decodes_request(self):
        xml = "<prelogin-response><status>Success</status><saml-auth-method>POST</saml-auth-method><saml-request>PGh0bWw+PC9odG1sPg==</saml-request></prelogin-response>"
        self.assertEqual(gp.parse_prelogin(xml), {"method": "POST", "request": "<html></html>"})
    def test_redirect_method(self):
        xml = "<prelogin-response><saml-auth-method>REDIRECT</saml-auth-method><saml-request>aHR0cHM6Ly9pZHAvc3Nv</saml-request></prelogin-response>"
        self.assertEqual(gp.parse_prelogin(xml)["request"], "https://idp/sso")
    def test_error_status_raises_with_message(self):
        xml = "<prelogin-response><status>Error</status><msg>Valid client certificate is required</msg></prelogin-response>"
        with self.assertRaises(gp.PreloginError) as cm: gp.parse_prelogin(xml)
        self.assertIn("client certificate", str(cm.exception))
    def test_missing_saml_raises(self):
        with self.assertRaises(gp.PreloginError): gp.parse_prelogin("<prelogin-response><status>Success</status></prelogin-response>")

class SamlResultTests(unittest.TestCase):
    def test_headers_win(self):
        r = gp.extract_saml_result({"Prelogin-Cookie": "abc", "saml-username": "b@x.com", "content-type": "text/html"}, None)
        self.assertEqual(r, {"prelogin-cookie": "abc", "saml-username": "b@x.com"})
    def test_html_comment(self):
        html = "<html><!-- <saml-auth-status>1</saml-auth-status><prelogin-cookie>zzz</prelogin-cookie><saml-username>b@x.com</saml-username><saml-slo>no</saml-slo> --></html>"
        r = gp.extract_saml_result(None, html)
        self.assertEqual(r["prelogin-cookie"], "zzz"); self.assertEqual(r["saml-username"], "b@x.com"); self.assertEqual(r["saml-auth-status"], "1")
    def test_complete_requires_username_and_cookie(self):
        self.assertFalse(gp.saml_result_complete({"saml-username": "u"}))
        self.assertFalse(gp.saml_result_complete({"prelogin-cookie": "c"}))
        self.assertTrue(gp.saml_result_complete({"saml-username": "u", "portal-userauthcookie": "c"}))
    def test_choose_cookie_prefers_prelogin(self):
        self.assertEqual(gp.choose_cookie({"prelogin-cookie": "p", "portal-userauthcookie": "u"}), ("prelogin-cookie", "p"))
        self.assertEqual(gp.choose_cookie({"portal-userauthcookie": "u"}), ("portal-userauthcookie", "u"))

class AuthenticateOutputTests(unittest.TestCase):
    def test_parses_quoted_values(self):
        text = "COOKIE='USER=b; AUTH=xyz'\nHOST='10.0.0.1'\nCONNECT_URL='https://gw.example.com/ssl-vpn/'\nFINGERPRINT='pin-sha256:AAAA'\n"
        a = gp.parse_authenticate_output(text)
        self.assertEqual(a["COOKIE"], "USER=b; AUTH=xyz"); self.assertEqual(a["CONNECT_URL"], "https://gw.example.com/ssl-vpn/")
        self.assertNotIn("RESOLVE", a)
    def test_ignores_noise_lines(self):
        a = gp.parse_authenticate_output("Connected to HTTPS on x\nCOOKIE=abc\nRESOLVE='gw.example.com:10.0.0.1'\n")
        self.assertEqual(a, {"COOKIE": "abc", "RESOLVE": "gw.example.com:10.0.0.1"})

class PasswdFileTests(unittest.TestCase):
    def test_renders_all_secrets(self):
        s = gp.render_passwd_file({"COOKIE": "c", "CONNECT_URL": "https://gw/", "FINGERPRINT": "pin-sha256:A", "RESOLVE": "gw:1.2.3.4"})
        self.assertEqual(s, "vpn.secrets.cookie:c\nvpn.secrets.gateway:https://gw/\nvpn.secrets.gwcert:pin-sha256:A\nvpn.secrets.resolve:gw:1.2.3.4\n")
    def test_omits_missing_resolve(self):
        s = gp.render_passwd_file({"COOKIE": "c", "CONNECT_URL": "https://gw/", "FINGERPRINT": "F"})
        self.assertNotIn("resolve", s)

class VpnDataTests(unittest.TestCase):
    def test_without_hip(self):
        self.assertEqual(gp.build_vpn_data("vpn.example.com", False, None),
            "gateway=vpn.example.com,protocol=gp,authtype=password,cookie-flags=2,gateway-flags=2,gwcert-flags=2,resolve-flags=2,enable_csd_trojan=no")
    def test_with_hip(self):
        self.assertTrue(gp.build_vpn_data("p", True, "/usr/lib/openconnect/hipreport.sh").endswith("enable_csd_trojan=yes,csd_wrapper=/usr/lib/openconnect/hipreport.sh"))

class NmcliTerseTests(unittest.TestCase):
    def test_unescapes_colons(self):
        d = gp.parse_nmcli_terse("GENERAL.STATE:activated\nIP4.ADDRESS[1]:10.1.2.3/32\nVPN.BANNER:a\\:b\n")
        self.assertEqual(d["GENERAL.STATE"], "activated"); self.assertEqual(d["IP4.ADDRESS[1]"], "10.1.2.3/32"); self.assertEqual(d["VPN.BANNER"], "a:b")

class DeriveStateTests(unittest.TestCase):
    deps = {"openconnect": True, "nmOpenconnect": True, "webkit": True}
    def test_unconfigured_without_portal(self):
        self.assertEqual(gp.derive_state(None, None, "", self.deps), "unconfigured")
    def test_missing_deps(self):
        self.assertEqual(gp.derive_state(None, None, "p", {**self.deps, "nmOpenconnect": False}), "missing-deps")
    def test_runfile_phase_wins_while_alive(self):
        self.assertEqual(gp.derive_state(None, {"phase": "signing-in", "alive": True}, "p", self.deps), "authenticating")
        self.assertEqual(gp.derive_state(None, {"phase": "activating", "alive": True}, "p", self.deps), "activating")
        self.assertEqual(gp.derive_state(None, {"phase": "activating", "alive": False}, "p", self.deps), "disconnected")
    def test_nm_states(self):
        self.assertEqual(gp.derive_state("activated", None, "p", self.deps), "connected")
        self.assertEqual(gp.derive_state("activating", None, "p", self.deps), "activating")
        self.assertEqual(gp.derive_state("deactivating", None, "p", self.deps), "disconnected")
```

- [ ] **Step 2: Run** `python3 -m unittest discover -s tests -v` — expected: import error / AttributeError for every test.
- [ ] **Step 3: Implement the helpers** (top of `bin/omarchy-globalprotect`)

```python
#!/usr/bin/env python3
"""omarchy-globalprotect: GlobalProtect (SAML / Google SSO) for Omarchy. NetworkManager owns the tunnel."""
import argparse, base64, json, os, re, shlex, shutil, subprocess, sys, time, urllib.parse, urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

APP = "omarchy-globalprotect"
NM_CONNECTION = "GlobalProtect"
CLIENT_OS = {"win": "Windows", "linux": "Linux", "mac": "Mac"}
COOKIE_KINDS = ("prelogin-cookie", "portal-userauthcookie")
SAML_FIELDS = COOKIE_KINDS + ("saml-username", "saml-auth-status")
HIP_SCRIPTS = ("/usr/lib/openconnect/hipreport.sh", "/usr/libexec/openconnect/hipreport.sh")

class PreloginError(Exception): pass
class AuthError(Exception): pass
class Cancelled(Exception): pass

def parse_prelogin(xml_text):
    try: root = ET.fromstring(xml_text)
    except ET.ParseError as e: raise PreloginError(f"Portal returned unreadable prelogin XML ({e})")
    status = (root.findtext("status") or "").strip()
    if status.lower() == "error":
        raise PreloginError((root.findtext("msg") or "Portal rejected prelogin").strip())
    method = (root.findtext("saml-auth-method") or "").strip().upper()
    request = (root.findtext("saml-request") or "").strip()
    if method not in ("POST", "REDIRECT") or not request:
        raise PreloginError("Portal did not offer SAML login (is SSO enabled for this portal?)")
    return {"method": method, "request": base64.b64decode(request).decode("utf-8", "replace")}

_COMMENT_RE = re.compile(r"<!--(.*?)-->", re.S)
_TAG_RE = re.compile(r"<(saml-username|saml-auth-status|prelogin-cookie|portal-userauthcookie)>(.*?)</\1>", re.S)

def extract_saml_result(headers, html):
    out = {}
    for name, value in (headers or {}).items():
        key = name.lower()
        if key in SAML_FIELDS and value: out[key] = value.strip()
    for comment in _COMMENT_RE.findall(html or ""):
        for key, value in _TAG_RE.findall(comment):
            if value.strip(): out.setdefault(key, value.strip())
    return out

def saml_result_complete(result):
    return bool(result.get("saml-username")) and any(result.get(k) for k in COOKIE_KINDS)

def choose_cookie(result):
    for kind in COOKIE_KINDS:
        if result.get(kind): return kind, result[kind]
    raise AuthError("SAML login finished without a cookie")

def parse_authenticate_output(text):
    out = {}
    for line in text.splitlines():
        m = re.match(r"^(COOKIE|HOST|CONNECT_URL|FINGERPRINT|RESOLVE)=(.*)$", line.strip())
        if not m: continue
        parts = shlex.split(m.group(2)) if m.group(2) else [""]
        out[m.group(1)] = parts[0] if parts else ""
    return out

def render_passwd_file(auth):
    lines = [f"vpn.secrets.cookie:{auth['COOKIE']}", f"vpn.secrets.gateway:{auth['CONNECT_URL']}", f"vpn.secrets.gwcert:{auth['FINGERPRINT']}"]
    if auth.get("RESOLVE"): lines.append(f"vpn.secrets.resolve:{auth['RESOLVE']}")
    return "\n".join(lines) + "\n"

def build_vpn_data(portal, hip, hip_script):
    data = f"gateway={portal},protocol=gp,authtype=password,cookie-flags=2,gateway-flags=2,gwcert-flags=2,resolve-flags=2,enable_csd_trojan={'yes' if hip else 'no'}"
    if hip and hip_script: data += f",csd_wrapper={hip_script}"
    return data

def parse_nmcli_terse(text):
    out = {}
    for line in text.splitlines():
        m = re.match(r"^((?:[^:\\]|\\.)+):(.*)$", line)
        if not m: continue
        out[m.group(1).replace("\\:", ":")] = m.group(2).replace("\\:", ":")
    return out

def derive_state(conn_state, runfile, portal, deps):
    if not portal: return "unconfigured"
    if not all(deps.get(k) for k in ("openconnect", "nmOpenconnect", "webkit")): return "missing-deps"
    if conn_state == "activated": return "connected"
    if runfile and runfile.get("alive"):
        return "activating" if runfile.get("phase") == "activating" else "authenticating"
    if conn_state == "activating": return "activating"
    return "disconnected"
```

- [ ] **Step 4: Run tests** — expected: all PASS. Make the file executable (`chmod +x`).
- [ ] **Step 5: Commit** `feat(cli): pure helpers for prelogin, SAML result, authenticate output, NM data`

---

### Task 3: CLI status, run file, deps, state file

**Files:** Modify `bin/omarchy-globalprotect`; Test `tests/test_cli.py`

**Produces:**
- `runtime_dir() -> Path` (`$XDG_RUNTIME_DIR/omarchy-globalprotect`), `state_dir() -> Path` (`$XDG_STATE_HOME/omarchy-globalprotect`), `data_dir()` (`$XDG_DATA_HOME/omarchy-globalprotect`)
- `write_runfile(phase)`, `clear_runfile()`, `read_runfile() -> dict|None` adds `alive` via `os.kill(pid, 0)`
- `load_state() -> dict`, `save_state(**kv)`
- `check_deps() -> dict`
- `nm_connection_state() -> str|None` (via `nmcli -t -f NAME,STATE connection show`)
- `nm_connection_details() -> dict` (`nmcli -t connection show GlobalProtect`)
- `iface_stats(iface) -> (rx, tx)`
- `status_json(portal) -> dict`
- `cmd_status(args)`

- [ ] **Step 1: Tests** (runfile staleness with a fake pid; state round trip using a temp `XDG_STATE_HOME`):

```python
class RunfileTests(unittest.TestCase):
    def test_dead_pid_reports_not_alive(self):
        with tempfile.TemporaryDirectory() as d, unittest.mock.patch.dict(os.environ, {"XDG_RUNTIME_DIR": d}):
            gp.write_runfile("signing-in", pid=999999)
            self.assertFalse(gp.read_runfile()["alive"])
            gp.clear_runfile(); self.assertIsNone(gp.read_runfile())
    def test_live_pid(self):
        with tempfile.TemporaryDirectory() as d, unittest.mock.patch.dict(os.environ, {"XDG_RUNTIME_DIR": d}):
            gp.write_runfile("activating"); self.assertTrue(gp.read_runfile()["alive"])
class StateFileTests(unittest.TestCase):
    def test_round_trip(self):
        with tempfile.TemporaryDirectory() as d, unittest.mock.patch.dict(os.environ, {"XDG_STATE_HOME": d}):
            gp.save_state(gateway="gw.example.com"); gp.save_state(username="b@x.com")
            self.assertEqual(gp.load_state(), {"gateway": "gw.example.com", "username": "b@x.com"})
```

- [ ] **Step 2: Run, expect failures. Step 3: implement.**

```python
def _xdg(var, default): return Path(os.environ.get(var) or default)
def runtime_dir(): d = _xdg("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}") / APP; d.mkdir(mode=0o700, parents=True, exist_ok=True); return d
def state_dir(): d = _xdg("XDG_STATE_HOME", Path.home() / ".local/state") / APP; d.mkdir(mode=0o700, parents=True, exist_ok=True); return d
def data_dir(): d = _xdg("XDG_DATA_HOME", Path.home() / ".local/share") / APP; d.mkdir(mode=0o700, parents=True, exist_ok=True); return d

def write_runfile(phase, pid=None):
    (runtime_dir() / "connect.json").write_text(json.dumps({"pid": pid or os.getpid(), "phase": phase, "at": time.time()}))
def clear_runfile():
    try: (runtime_dir() / "connect.json").unlink()
    except FileNotFoundError: pass
def read_runfile():
    try: d = json.loads((runtime_dir() / "connect.json").read_text())
    except (FileNotFoundError, ValueError): return None
    try: os.kill(int(d.get("pid", 0)), 0); d["alive"] = True
    except (OSError, ValueError): d["alive"] = False
    return d

def load_state():
    try: return json.loads((state_dir() / "state.json").read_text())
    except (FileNotFoundError, ValueError): return {}
def save_state(**kv):
    s = load_state(); s.update({k: v for k, v in kv.items() if v is not None})
    p = state_dir() / "state.json"; p.write_text(json.dumps(s)); p.chmod(0o600)

def check_deps():
    return {"openconnect": shutil.which("openconnect") is not None,
            "nmOpenconnect": Path("/usr/lib/NetworkManager/VPN/nm-openconnect-service.name").exists(),
            "webkit": Path("/usr/lib/girepository-1.0/WebKit2-4.1.typelib").exists()}

def run(cmd, timeout=15, input_text=None, check=False):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, input=input_text, check=check)

def nm_connection_state():
    try: r = run(["nmcli", "-t", "-f", "NAME,STATE", "connection", "show"])
    except (OSError, subprocess.TimeoutExpired): return None
    for line in r.stdout.splitlines():
        name, _, state = line.rpartition(":")
        if name == NM_CONNECTION: return state or "inactive"
    return None  # no profile yet

def nm_connection_details():
    try: r = run(["nmcli", "-t", "connection", "show", NM_CONNECTION])
    except (OSError, subprocess.TimeoutExpired): return {}
    return parse_nmcli_terse(r.stdout) if r.returncode == 0 else {}

def iface_stats(iface):
    try:
        base = Path("/sys/class/net") / iface / "statistics"
        return int((base / "rx_bytes").read_text()), int((base / "tx_bytes").read_text())
    except (OSError, ValueError): return 0, 0

def find_iface_for_ip(ip):
    try: devs = json.loads(run(["ip", "-j", "addr"]).stdout)
    except Exception: return ""
    for dev in devs:
        for a in dev.get("addr_info", []):
            if a.get("local") == ip: return dev.get("ifname", "")
    return ""

def status_json(portal):
    deps = check_deps(); runfile = read_runfile(); state_file = load_state()
    conn_state = nm_connection_state() if deps["nmOpenconnect"] else None
    state = derive_state(conn_state, runfile, portal, deps)
    out = {"state": state, "portal": portal, "gateway": state_file.get("gateway", ""), "username": state_file.get("username", ""),
           "hasSession": keyring_has(portal) if portal else False, "iface": "", "ip4": "", "since": 0, "rxBytes": 0, "txBytes": 0,
           "detail": "", "deps": deps}
    if state == "connected":
        d = nm_connection_details()
        ip = d.get("IP4.ADDRESS[1]", "").split("/")[0]
        iface = d.get("GENERAL.IP-IFACE") or find_iface_for_ip(ip)
        rx, tx = iface_stats(iface) if iface else (0, 0)
        out.update({"iface": iface, "ip4": ip, "since": int(d.get("connection.timestamp") or 0), "rxBytes": rx, "txBytes": tx})
    elif runfile and runfile.get("alive"): out["detail"] = runfile.get("phase", "")
    return out
```

`keyring_has` comes from Task 5; define a stub `def keyring_has(portal): return False` now and replace it in Task 5.

- [ ] **Step 4: Run tests; Step 5: Commit** `feat(cli): status, run file, state file, dependency probe`

---

### Task 4: SSO window (GTK3 + WebKitGTK)

**Files:** Modify `bin/omarchy-globalprotect`

**Produces:** `theme_colors() -> dict` (reads `~/.local/state/omarchy/current/theme/colors.toml`, keys background/foreground/accent, defaults if missing) and `run_sso_window(portal, method, request, timeout_s) -> dict` raising `Cancelled` or `AuthError`.

- [ ] **Step 1: Test for the colors reader** (pure):

```python
class ThemeColorTests(unittest.TestCase):
    def test_parses_minimal_toml(self):
        c = gp.parse_theme_colors('mode = "dark"\naccent = "#7d82d9"\nbackground = "#060B1E"\nforeground = "#ffcead"\n')
        self.assertEqual(c, {"accent": "#7d82d9", "background": "#060B1E", "foreground": "#ffcead"})
    def test_defaults_when_missing(self):
        self.assertEqual(gp.parse_theme_colors("")["background"], "#101315")
```

- [ ] **Step 2: Implement**

```python
def parse_theme_colors(text):
    colors = {"background": "#101315", "foreground": "#cacccc", "accent": "#cacccc"}
    for line in text.splitlines():
        m = re.match(r'^\s*(background|foreground|accent)\s*=\s*"(#[0-9A-Fa-f]{6})"', line)
        if m: colors[m.group(1)] = m.group(2)
    return colors

def theme_colors():
    p = _xdg("XDG_STATE_HOME", Path.home() / ".local/state") / "omarchy/current/theme/colors.toml"
    try: return parse_theme_colors(p.read_text())
    except OSError: return parse_theme_colors("")

def run_sso_window(portal, method, request, timeout_s=300):
    import gi
    gi.require_version("Gtk", "3.0"); gi.require_version("WebKit2", "4.1"); gi.require_version("Soup", "3.0")
    from gi.repository import GLib, Gtk, Gdk, WebKit2
    GLib.set_prgname(APP)
    colors = theme_colors(); wk = data_dir() / "webkit"; wk.mkdir(mode=0o700, exist_ok=True)
    manager = WebKit2.WebsiteDataManager(base_data_directory=str(wk / "data"), base_cache_directory=str(wk / "cache"))
    manager.get_cookie_manager().set_persistent_storage(str(wk / "cookies.sqlite"), WebKit2.CookiePersistentStorage.SQLITE)
    ctx = WebKit2.WebContext.new_with_website_data_manager(manager)
    view = WebKit2.WebView.new_with_context(ctx)
    outcome = {"result": {}, "error": None, "done": False}

    def finish(error=None):
        if outcome["done"]: return
        outcome["done"] = True; outcome["error"] = error
        title.set_text("Signed in" if error is None else "Sign-in stopped")
        GLib.timeout_add(600 if error is None else 0, lambda: (win.destroy(), False)[1])

    def consider(fields):
        if outcome["done"] or not fields: return
        outcome["result"].update({k: v for k, v in fields.items() if k not in outcome["result"]})
        if saml_result_complete(outcome["result"]): finish()

    def on_resource(_view, resource, _request):
        def on_finished(res):
            resp = res.get_response()
            if not resp: return
            headers = {}
            resp.get_http_headers().foreach(lambda n, v: headers.__setitem__(n, v))
            consider(extract_saml_result(headers, None))
        resource.connect("finished", on_finished)

    def on_load_changed(_view, event):
        progress.set_visible(event != WebKit2.LoadEvent.FINISHED)
        if event != WebKit2.LoadEvent.FINISHED: return
        def on_js(v, res):
            try: html = v.evaluate_javascript_finish(res).to_string()
            except Exception: return
            consider(extract_saml_result(None, html))
        view.evaluate_javascript("document.documentElement.outerHTML", -1, None, None, None, on_js)

    win = Gtk.Window(title=f"Sign in · {portal}"); win.set_default_size(480, 720); win.set_wmclass(APP, APP)
    css = Gtk.CssProvider(); css.load_from_data(f"""
      window, .gp-header {{ background: {colors['background']}; color: {colors['foreground']}; }}
      .gp-title {{ font-weight: bold; font-size: 13px; }} .gp-sub {{ opacity: 0.6; font-size: 11px; }}
      progressbar trough, progressbar progress {{ min-height: 2px; }} progressbar progress {{ background: {colors['accent']}; }}""".encode())
    Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL); header = Gtk.Box(spacing=8); header.get_style_context().add_class("gp-header")
    header.set_border_width(12); labels = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
    title = Gtk.Label(label="Signing in with Google", xalign=0); title.get_style_context().add_class("gp-title")
    sub = Gtk.Label(label=portal, xalign=0); sub.get_style_context().add_class("gp-sub")
    labels.pack_start(title, False, False, 0); labels.pack_start(sub, False, False, 0); header.pack_start(labels, True, True, 0)
    progress = Gtk.ProgressBar(); view.connect("notify::estimated-load-progress", lambda v, _p: progress.set_fraction(v.get_estimated_load_progress()))
    box.pack_start(header, False, False, 0); box.pack_start(progress, False, False, 0); box.pack_start(view, True, True, 0); win.add(box)
    view.connect("resource-load-started", on_resource); view.connect("load-changed", on_load_changed)
    view.connect("load-failed", lambda _v, _e, uri, err: (finish(f"Could not load {uri}: {err.message}"), True)[1])
    win.connect("destroy", lambda *_: (outcome["done"] or finish("Sign-in window closed"), Gtk.main_quit()))
    GLib.timeout_add_seconds(timeout_s, lambda: (finish("Sign-in timed out"), False)[1])
    if method == "REDIRECT": view.load_uri(request)
    else: view.load_html(request, f"https://{portal}/")
    win.show_all(); progress.set_visible(True); Gtk.main()
    if outcome["error"]:
        if "closed" in outcome["error"]: raise Cancelled(outcome["error"])
        raise AuthError(outcome["error"])
    return outcome["result"]
```

- [ ] **Step 3: Smoke test by hand** — `bin/omarchy-globalprotect login --portal <host>` once a portal is known; until then run `python3 -c` importing the module and calling `run_sso_window("example.com", "REDIRECT", "https://accounts.google.com/", 20)` to see the themed window open and time out cleanly (exit through `AuthError("Sign-in timed out")`).
- [ ] **Step 4: Commit** `feat(cli): themed WebKit sign-in window with SAML result capture`

---

### Task 5: CLI orchestration: keyring, NM profile, connect/disconnect/login/forget

**Files:** Modify `bin/omarchy-globalprotect`; Test `tests/test_cli.py`

**Produces:** `keyring_store(portal, cookie)`, `keyring_lookup(portal) -> str|None`, `keyring_has(portal) -> bool`, `keyring_clear(portal)`, `ensure_nm_profile(portal, hip, hip_script)`, `authenticate(...) -> dict`, `nm_up(auth)`, `nm_down()`, `authenticate_command(...) -> list[str]` (pure, tested), subcommands.

- [ ] **Step 1: Tests for the pure command builder**

```python
class AuthenticateCommandTests(unittest.TestCase):
    def test_builds_portal_prelogin_command(self):
        cmd = gp.authenticate_command("vpn.example.com", "prelogin-cookie", "b@x.com", "win", "", None)
        self.assertEqual(cmd, ["openconnect", "--protocol=gp", "--authenticate", "--non-inter", "--os=win", "--user=b@x.com",
                               "--usergroup=portal:prelogin-cookie", "--passwd-on-stdin", "vpn.example.com"])
    def test_gateway_and_hip(self):
        cmd = gp.authenticate_command("p", "portal-userauthcookie", "u", "linux", "GW-EU", "/usr/lib/openconnect/hipreport.sh")
        self.assertIn("--authgroup=GW-EU", cmd); self.assertIn("--csd-wrapper=/usr/lib/openconnect/hipreport.sh", cmd)
    def test_cookie_never_in_argv(self):
        self.assertNotIn("SECRET", " ".join(gp.authenticate_command("p", "prelogin-cookie", "u", "win", "", None)))
```

- [ ] **Step 2: Implement**

```python
def authenticate_command(portal, cookie_kind, username, client_os, gateway, hip_script):
    cmd = ["openconnect", "--protocol=gp", "--authenticate", "--non-inter", f"--os={client_os}", f"--user={username}",
           f"--usergroup=portal:{cookie_kind}", "--passwd-on-stdin"]
    if gateway: cmd.append(f"--authgroup={gateway}")
    if hip_script: cmd.append(f"--csd-wrapper={hip_script}")
    cmd.append(portal); return cmd

def authenticate(portal, cookie_kind, cookie, username, client_os, gateway, hip_script, timeout=60):
    try: r = run(authenticate_command(portal, cookie_kind, username, client_os, gateway, hip_script), timeout=timeout, input_text=cookie + "\n")
    except subprocess.TimeoutExpired: raise AuthError("openconnect timed out talking to the portal")
    auth = parse_authenticate_output(r.stdout)
    if r.returncode != 0 or not all(auth.get(k) for k in ("COOKIE", "CONNECT_URL", "FINGERPRINT")):
        raise AuthError(last_meaningful_line(r.stderr) or "Portal login failed")
    return auth

def last_meaningful_line(text):
    lines = [l.strip() for l in text.splitlines() if l.strip() and not l.startswith(("Connected to", "SSL negotiation", "Connected to HTTPS"))]
    return lines[-1][:200] if lines else ""

KEYRING_ATTRS = lambda portal: ["application", APP, "portal", portal, "kind", "portal-userauthcookie"]
def keyring_store(portal, cookie):
    run(["secret-tool", "store", f"--label=GlobalProtect session ({portal})", *KEYRING_ATTRS(portal)], input_text=cookie)
def keyring_lookup(portal):
    try: r = run(["secret-tool", "lookup", *KEYRING_ATTRS(portal)])
    except OSError: return None
    return r.stdout.strip() or None if r.returncode == 0 else None
def keyring_has(portal): return keyring_lookup(portal) is not None
def keyring_clear(portal):
    try: run(["secret-tool", "clear", "application", APP, "portal", portal])
    except OSError: pass

def hip_script_path():
    return next((p for p in HIP_SCRIPTS if Path(p).exists()), None)

def ensure_nm_profile(portal, hip):
    data = build_vpn_data(portal, hip, hip_script_path() if hip else None)
    user = os.environ.get("USER") or os.getlogin()
    if nm_connection_state() is None:
        r = run(["nmcli", "connection", "add", "type", "vpn", "con-name", NM_CONNECTION, "ifname", "*", "vpn-type", "openconnect",
                 "connection.permissions", f"user:{user}", "vpn.data", data], timeout=20)
    else:
        r = run(["nmcli", "connection", "modify", NM_CONNECTION, "connection.permissions", f"user:{user}", "vpn.data", data], timeout=20)
    if r.returncode != 0: raise AuthError(f"NetworkManager profile setup failed: {last_meaningful_line(r.stderr)}")

def nm_up(auth, timeout=60):
    path = runtime_dir() / f"secrets.{os.getpid()}"
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w") as f: f.write(render_passwd_file(auth))
        r = run(["nmcli", "--wait", str(timeout), "connection", "up", NM_CONNECTION, "passwd-file", str(path)], timeout=timeout + 10)
        if r.returncode != 0: raise AuthError(last_meaningful_line(r.stderr) or "NetworkManager could not bring the tunnel up")
    finally:
        try: path.unlink()
        except FileNotFoundError: pass

def nm_down():
    r = run(["nmcli", "connection", "down", NM_CONNECTION], timeout=30)
    if r.returncode != 0 and "not an active connection" not in r.stderr: raise AuthError(last_meaningful_line(r.stderr) or "Disconnect failed")

def emit(phase):
    print(f"phase={phase}", flush=True); write_runfile(phase)

def fail(msg, code=1):
    print(f"error={msg}", file=sys.stderr, flush=True); clear_runfile(); sys.exit(code)

def sign_in(portal, client_os):
    emit("signing-in")
    pre = prelogin(portal, CLIENT_OS.get(client_os, "Windows"))
    result = run_sso_window(portal, pre["method"], pre["request"])
    kind, cookie = choose_cookie(result); username = result["saml-username"]
    if result.get("portal-userauthcookie"): keyring_store(portal, result["portal-userauthcookie"])
    save_state(username=username, portal=portal)
    return kind, cookie, username

def prelogin(portal, client_os, timeout=20):
    body = urllib.parse.urlencode({"tmp": "tmp", "kerberos-support": "yes", "ipv6-support": "yes", "clientVer": "4100", "clientos": client_os}).encode()
    req = urllib.request.Request(f"https://{portal}/global-protect/prelogin.esp", data=body, method="POST", headers={"User-Agent": "PAN GlobalProtect"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp: return parse_prelogin(resp.read().decode("utf-8", "replace"))
    except urllib.error.URLError as e: raise PreloginError(f"Could not reach {portal}: {e.reason}")

def cmd_connect(args):
    portal = (args.portal or load_state().get("portal") or "").strip()
    if not portal: fail("No portal configured", 1)
    deps = check_deps()
    if not all(deps.values()): fail("Missing dependencies: " + ", ".join(k for k, v in deps.items() if not v), 3)
    try:
        emit("preparing"); ensure_nm_profile(portal, args.hip)
        hip_script = hip_script_path() if args.hip else None
        auth = None; username = load_state().get("username", "")
        if not args.fresh and username:
            cookie = keyring_lookup(portal)
            if cookie:
                emit("authenticating")
                try: auth = authenticate(portal, "portal-userauthcookie", cookie, username, args.client_os, args.gateway, hip_script)
                except AuthError: keyring_clear(portal); auth = None
        if auth is None:
            kind, cookie, username = sign_in(portal, args.client_os)
            emit("authenticating")
            auth = authenticate(portal, kind, cookie, username, args.client_os, args.gateway, hip_script)
        save_state(gateway=urllib.parse.urlsplit(auth["CONNECT_URL"]).hostname or "", portal=portal)
        emit("activating"); nm_up(auth); emit("connected"); clear_runfile()
    except Cancelled as e: fail(str(e), 2)
    except (PreloginError, AuthError) as e: fail(str(e), 1)
    except KeyboardInterrupt: fail("Interrupted", 2)

def cmd_login(args):
    portal = (args.portal or load_state().get("portal") or "").strip()
    if not portal: fail("No portal configured")
    try: sign_in(portal, args.client_os); clear_runfile(); print("phase=signed-in")
    except Cancelled as e: fail(str(e), 2)
    except (PreloginError, AuthError) as e: fail(str(e))

def cmd_disconnect(args):
    try: nm_down()
    except AuthError as e: fail(str(e))

def cmd_forget(args):
    portal = (args.portal or load_state().get("portal") or "").strip()
    if portal: keyring_clear(portal)
    shutil.rmtree(data_dir() / "webkit", ignore_errors=True)
    s = load_state(); s.pop("username", None); (state_dir() / "state.json").write_text(json.dumps(s))

def cmd_status(args):
    portal = (args.portal or load_state().get("portal") or "").strip()
    print(json.dumps(status_json(portal)))

def cmd_deps(args): print(json.dumps(check_deps()))

def main(argv=None):
    p = argparse.ArgumentParser(prog=APP); sub = p.add_subparsers(dest="cmd", required=True)
    def common(sp):
        sp.add_argument("--portal", default=""); sp.add_argument("--gateway", default=""); sp.add_argument("--client-os", dest="client_os", default="win", choices=list(CLIENT_OS))
        sp.add_argument("--hip", action="store_true"); sp.add_argument("--fresh", action="store_true")
    for name, fn in (("status", cmd_status), ("connect", cmd_connect), ("disconnect", cmd_disconnect), ("login", cmd_login), ("forget", cmd_forget), ("deps", cmd_deps)):
        sp = sub.add_parser(name); common(sp); sp.set_defaults(fn=fn)
    args = p.parse_args(argv); args.fn(args)

if __name__ == "__main__": main()
```

- [ ] **Step 3: Run `scripts/check`** — all tests pass; `bin/omarchy-globalprotect status` prints JSON with `"state": "unconfigured"` (no portal) or `"missing-deps"`.
- [ ] **Step 4: Commit** `feat(cli): connect/disconnect/login/forget orchestration with keyring and NM profile`

---

### Task 6: Model.js and GpIcon.qml

**Files:** Create `Model.js`, `GpIcon.qml`

**Produces (Model.js):** `normalizeStatus(raw) -> object` (safe defaults for every field in the status JSON), `formatBytesPerSec(n) -> string`, `formatDuration(seconds) -> string` ("1h 02m", "45s"), `pushSample(history, value, max) -> array`, `PHRASES` array, `stateText(status) -> string`.

**Produces (GpIcon.qml):** properties `iconSize`, `color`, `ringColor`, `state` ("off"|"busy"|"on"|"error"), `badgeColor`.

- [ ] **Step 1: Write Model.js**

```javascript
.pragma library

var PHRASES = ["Tunnel sealed", "Packets escorted", "Routes guarded", "Handshake held", "Keys turning", "Gateway humming", "Wires whispering", "Portal aligned"]

function normalizeStatus(raw) {
  var s = raw && typeof raw === "object" ? raw : {}
  return {
    state: typeof s.state === "string" ? s.state : "disconnected",
    portal: String(s.portal || ""), gateway: String(s.gateway || ""), username: String(s.username || ""),
    hasSession: s.hasSession === true, iface: String(s.iface || ""), ip4: String(s.ip4 || ""),
    since: Number(s.since) || 0, rxBytes: Number(s.rxBytes) || 0, txBytes: Number(s.txBytes) || 0,
    detail: String(s.detail || ""),
    deps: { openconnect: !!(s.deps && s.deps.openconnect), nmOpenconnect: !!(s.deps && s.deps.nmOpenconnect), webkit: !!(s.deps && s.deps.webkit) }
  }
}

function stateText(state, portal) {
  switch (state) {
    case "unconfigured": return "Set a portal to get started"
    case "missing-deps": return "Needs networkmanager-openconnect"
    case "authenticating": return "Signing in…"
    case "activating": return "Bringing the tunnel up…"
    case "connected": return "Connected"
    case "error": return "Something went wrong"
    default: return portal ? "Disconnected" : "Disconnected"
  }
}

function formatBytesPerSec(n) {
  n = Math.max(0, Number(n) || 0)
  if (n < 1024) return Math.round(n) + " B/s"
  if (n < 1024 * 1024) return (n / 1024).toFixed(n < 10240 ? 1 : 0) + " KB/s"
  return (n / (1024 * 1024)).toFixed(1) + " MB/s"
}

function formatDuration(seconds) {
  seconds = Math.max(0, Math.floor(Number(seconds) || 0))
  var h = Math.floor(seconds / 3600), m = Math.floor((seconds % 3600) / 60), s = seconds % 60
  if (h > 0) return h + "h " + (m < 10 ? "0" : "") + m + "m"
  if (m > 0) return m + "m " + (s < 10 ? "0" : "") + s + "s"
  return s + "s"
}

function pushSample(history, value, max) {
  var next = (history || []).slice(); next.push(Math.max(0, Number(value) || 0))
  while (next.length > max) next.shift()
  return next
}
```

- [ ] **Step 2: Write GpIcon.qml** — a shield silhouette from a `Shape` path, a keyhole dot, and a ring arc:

```qml
import QtQuick
import QtQuick.Shapes
import qs.Commons

Item {
  id: root
  property real iconSize: Style.font.icon
  property color color: Color.foreground
  property color ringColor: color
  property color badgeColor: Color.urgent
  property string state: "off"   // off | busy | on | error
  width: iconSize; height: iconSize; implicitWidth: iconSize; implicitHeight: iconSize

  readonly property bool busy: state === "busy"
  readonly property bool on: state === "on"
  readonly property real ringSweep: on ? 360 : (busy ? 100 : 0)
  Behavior on ringSweep { NumberAnimation { duration: 360; easing.type: Easing.InOutCubic } }

  Shape {
    id: shield
    anchors.fill: parent
    preferredRendererType: Shape.CurveRenderer
    opacity: root.state === "off" ? 0.55 : 1.0
    Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
    ShapePath {
      strokeWidth: 0; fillColor: root.color
      readonly property real w: root.iconSize; readonly property real h: root.iconSize
      startX: w * 0.5; startY: h * 0.06
      PathLine { x: root.iconSize * 0.88; y: root.iconSize * 0.22 }
      PathCubic { x: root.iconSize * 0.5; y: root.iconSize * 0.96; control1X: root.iconSize * 0.9; control1Y: root.iconSize * 0.7; control2X: root.iconSize * 0.72; control2Y: root.iconSize * 0.88 }
      PathCubic { x: root.iconSize * 0.12; y: root.iconSize * 0.22; control1X: root.iconSize * 0.28; control1Y: root.iconSize * 0.88; control2X: root.iconSize * 0.1; control2Y: root.iconSize * 0.7 }
      PathLine { x: root.iconSize * 0.5; y: root.iconSize * 0.06 }
    }
  }

  Rectangle {  // keyhole
    width: Math.max(2, root.iconSize * 0.2); height: width; radius: width / 2
    color: Color.background; anchors.centerIn: parent; anchors.verticalCenterOffset: -root.iconSize * 0.06
    opacity: root.state === "off" ? 0.55 : 1.0
  }

  Shape {  // orbiting / sealing ring
    id: ring
    anchors.centerIn: parent; width: root.iconSize * 1.5; height: width
    visible: root.ringSweep > 0.5
    opacity: root.on ? 0.35 : 1.0
    Behavior on opacity { NumberAnimation { duration: 360; easing.type: Easing.InOutCubic } }
    ShapePath {
      strokeColor: root.ringColor; strokeWidth: Math.max(1.5, root.iconSize * 0.09); fillColor: "transparent"; capStyle: ShapePath.RoundCap
      PathAngleArc { centerX: ring.width / 2; centerY: ring.height / 2; radiusX: ring.width / 2 - 2; radiusY: ring.height / 2 - 2; startAngle: -90; sweepAngle: root.ringSweep }
    }
    NumberAnimation on rotation { from: 0; to: 360; duration: 1100; loops: Animation.Infinite; running: root.busy; easing.type: Easing.InOutCubic }
    onRotationChanged: if (!root.busy && rotation !== 0 && !rotationReset.running) rotationReset.start()
    NumberAnimation { id: rotationReset; target: ring; property: "rotation"; to: 0; duration: 240; easing.type: Easing.OutCubic }
  }

  Rectangle {  // error badge
    visible: root.state === "error"
    width: Math.max(5, root.iconSize * 0.34); height: width; radius: width / 2
    color: root.badgeColor; anchors.right: parent.right; anchors.bottom: parent.bottom
    border.width: 1; border.color: Color.popups.background
  }
}
```

- [ ] **Step 3: Verify** with `scripts/check` (validator) and, once Panel.qml exists, visually. **Step 4: Commit** `feat(ui): model helpers and animated shield icon`

---

### Task 7: Service.qml

**Files:** Create `Service.qml`

**Consumes:** CLI contract (`status --json`, `connect` phase lines and exit codes 0/1/2/3, `disconnect`, `login`, `forget`), `Model.normalizeStatus`.

**Produces (properties):** `state`, `detail`, `portal`, `gateway`, `iface`, `ip4`, `since`, `rxBytes`, `txBytes`, `rxRate`, `txRate`, `rxHistory`, `txHistory`, `username`, `hasSession`, `deps`, `active` (optimistic), `busy`, `actionStatus`, `lastError`, `cliPath`, `panelOpen`; functions `refresh()`, `connect()`, `disconnect()`, `toggle()`, `signInAgain()`, `forget()`, `copyAddress()`.

- [ ] **Step 1: Write Service.qml**

```qml
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

Item {
  id: root
  property var settings: ({})
  property string cliPath: ""
  property bool panelOpen: false

  function setting(name, fallback) { var v = settings ? settings[name] : undefined; return v === undefined || v === null ? fallback : v }
  readonly property string portal: String(setting("portal", "")).trim()
  readonly property string gateway: String(setting("gateway", "")).trim()
  readonly property string clientOs: ["win", "linux", "mac"].indexOf(String(setting("clientOs", "win"))) >= 0 ? String(setting("clientOs", "win")) : "win"
  readonly property bool hipReport: setting("hipReport", false) === true
  readonly property int refreshIntervalSec: Math.min(120, Math.max(2, parseInt(String(setting("refreshIntervalSec", 5)), 10) || 5))

  property string state: "disconnected"
  property string detail: ""
  property string gatewayHost: ""
  property string iface: ""
  property string ip4: ""
  property double since: 0
  property double rxBytes: 0
  property double txBytes: 0
  property real rxRate: 0
  property real txRate: 0
  property var rxHistory: []
  property var txHistory: []
  property string username: ""
  property bool hasSession: false
  property var deps: ({ openconnect: false, nmOpenconnect: false, webkit: false })
  property string actionStatus: ""
  property string lastError: ""
  property int _desired: -1
  property double _lastSampleMs: 0
  property double _lastRx: 0
  property double _lastTx: 0
  property string _connectErr: ""
  property string _lastNotifiedState: ""

  readonly property bool connected: state === "connected"
  readonly property bool transitioning: state === "authenticating" || state === "activating" || connectProc.running || disconnectProc.running
  readonly property bool active: _desired === -1 ? (connected || state === "authenticating" || state === "activating") : _desired === 1
  readonly property bool busy: transitioning || forgetProc.running
  readonly property bool configured: portal !== ""
  readonly property bool depsOk: deps.openconnect && deps.nmOpenconnect && deps.webkit

  function cliArgs(cmd, extra) {
    var args = [cliPath, cmd, "--portal", portal, "--gateway", gateway, "--client-os", clientOs]
    if (hipReport) args.push("--hip")
    return args.concat(extra || [])
  }

  function refresh() {
    if (cliPath === "" || statusProc.running) return
    statusProc.command = cliArgs("status")
    statusProc.running = true
    if (!pollWatchdog.running) pollWatchdog.start()
  }

  function applyStatus(raw) {
    var s = Model.normalizeStatus(raw)
    var previous = state
    if (!(connectProc.running && (s.state === "disconnected"))) state = s.state
    detail = s.detail; gatewayHost = s.gateway; iface = s.iface; ip4 = s.ip4; since = s.since
    username = s.username; hasSession = s.hasSession; deps = s.deps
    sample(s.rxBytes, s.txBytes)
    if (_desired !== -1 && (connected === (_desired === 1)) && !transitioning) _desired = -1
    if (state !== "connected" && previous === "connected" && !disconnectProc.running && _desired !== 0) notify("Disconnected", "GlobalProtect tunnel went down", "network-vpn-disconnected")
    if (state === "connected" && previous !== "connected") notify("Connected", gatewayHost ? "Through " + gatewayHost : "GlobalProtect tunnel is up", "network-vpn")
  }

  function sample(rx, tx) {
    var now = Date.now()
    if (_lastSampleMs > 0 && now > _lastSampleMs && rx >= _lastRx && tx >= _lastTx) {
      var dt = (now - _lastSampleMs) / 1000
      rxRate = (rx - _lastRx) / dt; txRate = (tx - _lastTx) / dt
      rxHistory = Model.pushSample(rxHistory, rxRate, 40); txHistory = Model.pushSample(txHistory, txRate, 40)
    }
    _lastSampleMs = now; _lastRx = rx; _lastTx = tx; rxBytes = rx; txBytes = tx
  }

  function connect(fresh) {
    if (!configured || connectProc.running) return
    if (!depsOk) { lastError = "Install networkmanager-openconnect first"; return }
    _desired = 1; lastError = ""; _connectErr = ""; actionStatus = ""
    state = "authenticating"
    connectProc.command = cliArgs("connect", fresh ? ["--fresh"] : [])
    connectProc.running = true
  }
  function disconnect() {
    if (disconnectProc.running) return
    _desired = 0; lastError = ""
    if (connectProc.running) { connectProc.signal(15); return }
    disconnectProc.command = cliArgs("disconnect"); disconnectProc.running = true
  }
  function toggle() { if (active) disconnect(); else connect(false) }
  function signInAgain() { if (connected) { _desired = 1; disconnectThenConnect.start(); disconnectProc.command = cliArgs("disconnect"); disconnectProc.running = true } else connect(true) }
  function forget() { if (forgetProc.running) return; forgetProc.command = cliArgs("forget"); forgetProc.running = true }
  function copyAddress() {
    if (ip4 === "") return
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(ip4) + " | wl-copy"])
    flash("Copied " + ip4)
  }
  function flash(text) { actionStatus = text; actionStatusTimer.restart() }
  function notify(title, body, icon) {
    Quickshell.execDetached(["notify-send", "-a", "GlobalProtect", "-i", icon, "-e", title, body])
  }

  Timer { id: refreshTimer; interval: (root.panelOpen ? root.refreshIntervalSec : root.refreshIntervalSec * 4) * 1000; repeat: true; running: root.cliPath !== ""; triggeredOnStart: true; onTriggered: root.refresh() }
  Timer { id: fastSample; interval: 1000; repeat: true; running: root.panelOpen && root.connected; onTriggered: root.refresh() }
  Timer { id: monitorDebounce; interval: 400; repeat: false; onTriggered: root.refresh() }
  Timer { id: delayedRefresh; interval: 600; repeat: false; onTriggered: root.refresh() }
  Timer { id: pollWatchdog; interval: 15000; repeat: false; onTriggered: if (statusProc.running) statusProc.running = false }
  Timer { id: actionStatusTimer; interval: 2200; repeat: false; onTriggered: root.actionStatus = "" }
  Timer { id: disconnectThenConnect; interval: 800; repeat: false; onTriggered: root.connect(true) }
  Timer { id: monitorRestart; interval: 3000; repeat: false; onTriggered: monitorProc.running = true }

  Process {
    id: statusProc
    stdout: StdioCollector { id: statusOut; waitForEnd: true }
    onExited: function(code) {
      var parsed = null
      try { parsed = JSON.parse(statusOut.text) } catch (e) {}
      if (code === 0 && parsed) root.applyStatus(parsed)
    }
  }

  Process {
    id: monitorProc
    command: ["nmcli", "monitor"]
    running: true
    stdout: SplitParser { onRead: function(line) { if (/GlobalProtect|VPN|vpn/.test(line)) monitorDebounce.restart() } }
    onExited: monitorRestart.start()
  }

  Process {
    id: connectProc
    stdout: SplitParser {
      onRead: function(line) {
        var m = String(line).match(/^phase=(\S+)/)
        if (!m) return
        if (m[1] === "signing-in" || m[1] === "authenticating" || m[1] === "preparing") root.state = "authenticating"
        else if (m[1] === "activating") root.state = "activating"
        else if (m[1] === "connected") root.state = "connected"
      }
    }
    stderr: SplitParser { onRead: function(line) { var m = String(line).match(/^error=(.*)$/); if (m) root._connectErr = m[1] } }
    onExited: function(code) {
      if (code === 0) { root.lastError = "" }
      else if (code === 2) { root._desired = -1; root.state = "disconnected"; root.flash("Sign-in cancelled") }
      else { root._desired = -1; root.state = "error"; root.lastError = root._connectErr || "Connection failed"; root.notify("Connection failed", root.lastError, "dialog-error") }
      delayedRefresh.restart()
    }
  }

  Process {
    id: disconnectProc
    stderr: StdioCollector { id: disconnectErr; waitForEnd: true }
    onExited: function(code) {
      if (code !== 0) { root._desired = -1; root.lastError = String(disconnectErr.text || "").replace(/^error=/, "").trim() || "Disconnect failed" }
      else if (!disconnectThenConnect.running) root.notify("Disconnected", "GlobalProtect tunnel closed", "network-vpn-disconnected")
      delayedRefresh.restart()
    }
  }

  Process { id: forgetProc; onExited: function(code) { root.flash(code === 0 ? "Session forgotten" : "Could not forget session"); delayedRefresh.restart() } }
}
```

- [ ] **Step 2: Load check** — with Panel.qml from Task 8 in place the shell logs no QML errors: `journalctl --user -u omarchy-shell -n 50` or the quickshell log under `/run/user/1000/quickshell/`.
- [ ] **Step 3: Commit** `feat(ui): service state machine over the CLI and nmcli monitor`

---

### Task 8: Panel.qml

**Files:** Create `Panel.qml`

**Consumes:** every Service property/function above; `GpIcon`; `Model.PHRASES`, `Model.stateText`, `Model.formatDuration`, `Model.formatBytesPerSec`.

Structure (follow the Tailscale panel closely):

- [ ] **Step 1: Skeleton, bar button, IPC, key catcher**

```qml
import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "brianirish.globalprotect"
  ipcTarget: "brianirish.globalprotect"
  manageIpc: false

  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color barIconColor: gp.active ? barForeground : Qt.darker(barForeground, 1.55)
  readonly property string iconState: gp.state === "error" ? "error" : (gp.transitioning ? "busy" : (gp.connected ? "on" : "off"))

  property int phraseIndex: 0
  property bool cursorActive: false
  property int cursorIndex: 0
  property string portalDraft: ""
  property double nowMs: Date.now()
  readonly property var cursorRows: rowsForCursor()
  readonly property string heroMeta: gp.connected ? Model.PHRASES[phraseIndex % Model.PHRASES.length] : Model.stateText(gp.state, gp.portal)

  function rowsForCursor() {
    var rows = ["header"]
    if (gp.connected && gp.ip4 !== "") rows.push("address")
    if (gp.username !== "" || gp.hasSession) rows.push("signin", "forget")
    if (!gp.depsOk && gp.configured) rows.push("install")
    return rows
  }
  function saveSetting(key, value) {
    var next = Object.assign({}, root.settings); next[key] = value
    root.settings = next
    if (root.bar && root.bar.shell) root.bar.shell.updateEntryInline(root.moduleName, Object.assign({ id: root.moduleName }, next))
  }
  function activateCursor() {
    var row = cursorRows[Math.max(0, Math.min(cursorIndex, cursorRows.length - 1))]
    if (row === "header") gp.toggle(); else if (row === "address") gp.copyAddress(); else if (row === "signin") gp.signInAgain()
    else if (row === "forget") forgetDialog.opened = true; else if (row === "install") root.installDeps()
  }
  function installDeps() { root.bar.run(root.pluginDir + "/bin/omarchy-globalprotect-install-deps"); gp.flash("Installing…"); depsRecheck.start() }

  onOpenedChanged: { gp.panelOpen = opened; if (opened) { gp.refresh(); cursorActive = false; cursorIndex = 0 } }
  Component.onCompleted: gp.cliPath = root.pluginDir + "/bin/omarchy-globalprotect"

  Service { id: gp; settings: root.settings }
  Timer { id: clockTick; interval: 1000; repeat: true; running: root.opened && gp.connected; onTriggered: root.nowMs = Date.now() }
  Timer { id: depsRecheck; interval: 4000; repeat: true; running: false; onTriggered: { gp.refresh(); if (gp.depsOk) running = false } }
  Timer { id: phraseTimer; interval: 2800; repeat: true; running: root.opened && gp.connected; onTriggered: phraseSwap.restart() }
  SequentialAnimation {
    id: phraseSwap
    PropertyAnimation { target: hero; property: "metaOpacity"; to: 0; duration: 180; easing.type: Easing.OutQuad }
    ScriptAction { script: root.phraseIndex = (root.phraseIndex + 1) % Model.PHRASES.length }
    PropertyAnimation { target: hero; property: "metaOpacity"; to: 1; duration: 260; easing.type: Easing.InQuad }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function connect(): string { gp.connect(false); return "ok" }
    function disconnect(): string { gp.disconnect(); return "ok" }
    function toggleVpn(): string { gp.toggle(); return "ok" }
    function status(): string { return gp.state }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: root.opened ? "" : ("GlobalProtect · " + Model.stateText(gp.state, gp.portal))
    iconComponent: Component {
      Item {
        GpIcon {
          anchors.centerIn: parent
          iconSize: Style.space(11)
          color: root.barIconColor
          ringColor: root.barForeground
          badgeColor: root.urgent
          state: root.iconState
          Behavior on color { ColorAnimation { duration: 160 } }
          SequentialAnimation on opacity {
            running: gp.transitioning
            loops: Animation.Infinite
            NumberAnimation { to: 0.45; duration: 420; easing.type: Easing.InOutQuad }
            NumberAnimation { to: 1.0; duration: 420; easing.type: Easing.InOutQuad }
            onRunningChanged: if (!running) parent.opacity = 1.0
          }
        }
      }
    }
    onPressed: function(b) { if (b === Qt.RightButton) gp.toggle(); else if (b === Qt.MiddleButton) gp.refresh(); else root.toggle() }
  }
  ...
}
```

- [ ] **Step 2: KeyboardPanel with the sections listed in the spec** (hero + status line + SESSION + ACCOUNT + SETUP + INSTALL + SETTINGS). Each section is a `Column` with `visible` bound to state, wrapped so it animates:

```qml
component Section: Column {
  property bool shown: true
  width: parent.width; spacing: Style.space(10)
  visible: opacity > 0.01
  opacity: shown ? 1 : 0
  Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
}
```

Key rows:
- Header uses `PanelHero` with `iconComponent: GpIcon { iconSize: Style.font.display; state: root.iconState; ... }`, `title: "GlobalProtect"`, `meta: root.heroMeta`, `detail: gp.connected && gp.gatewayHost ? gp.gatewayHost : ""`, and `trailingControl: ToggleSwitch { checked: gp.active; busy: gp.busy; interactive: gp.configured && gp.depsOk; onToggled: gp.toggle() }`.
- Status line `Text` shows `gp.actionStatus || gp.lastError`, urgent color for errors, `Behavior on opacity 180ms`.
- SESSION rows are `CursorSurface` rows: label left (dim), value right; the address row copies on click; connected-for value is `Model.formatDuration(root.nowMs / 1000 - gp.since)`; throughput row hosts a `Canvas` sparkline (`onPaint` draws `gp.rxHistory` as a filled polyline in `Util.alpha(root.foreground, 0.25)` and `gp.txHistory` as a stroke) and a caption "↓ … ↑ …" with `Model.formatBytesPerSec`. Repaint on `gp.rxHistoryChanged`.
- ACCOUNT: "Signed in as <username>" (or "Session stored" when only `hasSession`), two bordered `Button`s: "Sign in again" (`iconText: ""`, `iconSpinning: gp.state === "authenticating"`) and "Forget session" (opens `ConfirmDialog { message: "Forget the stored session and Google login?"; confirmText: "Forget"; onConfirmed: gp.forget() }`).
- SETUP (unconfigured): `TextField { placeholderText: "vpn.example.com"; text: root.portalDraft; onAccepted: root.savePortal() }` + `Button { text: "Save" }`; `savePortal()` trims, strips `https://` and trailing `/`, then `saveSetting("portal", host)`.
- INSTALL (missing deps): explanatory `Text` + `Button { text: "Install networkmanager-openconnect"; onClicked: root.installDeps() }`.
- SETTINGS: `PanelSectionHeader "SETTINGS"`, `TextField` for gateway (`onEditingFinished: root.saveSetting("gateway", text.trim())`), `Toggle { label: "HIP report"; description: "Send a host-integrity report if your portal requires it"; checked: gp.hipReport; onClicked: root.saveSetting("hipReport", !gp.hipReport) }`.

Keyboard (in `PanelKeyCatcher`): `onMoveRequested` moves `cursorIndex` within `cursorRows`; `onActivateRequested` → `activateCursor()`; `onTextKey`: `t` toggle, `r` refresh, `c` copy, `s` sign in again, `f` forget dialog; `onCloseRequested` closes the dialog first if open, else the panel; `onTabRequested` → `root.switchPanel(direction)`; `blocked: forgetDialog.opened || portalField.activeFocus`.

- [ ] **Step 3: Enable and verify live**

```bash
omarchy plugin validate ~/.config/omarchy/plugins/brianirish.globalprotect
omarchy plugin enable brianirish.globalprotect
omarchy-shell shell rescanPlugins
omarchy-shell brianirish.globalprotect open
omarchy capture screenshot   # or grim for a still of the panel
```
Expected: icon in the right bar section; panel opens with the SETUP section; saving a portal flips the hero to "Disconnected" with an enabled toggle; no errors in the quickshell log.

- [ ] **Step 4: Commit** `feat(ui): GlobalProtect panel with hero, session stats, account, setup, settings`

---

### Task 9: Integration: window rule, dependencies, docs

**Files:** Modify `~/.config/hypr/hyprland.lua` (append), Create `README.md`, `CHANGELOG.md`

- [ ] **Step 1: Window rule** — append to `~/.config/hypr/hyprland.lua`:

```lua
-- GlobalProtect sign-in window (brianirish.globalprotect plugin): float it, centered.
o.window({ class = "^omarchy-globalprotect$" }, { float = true, center = true, size = "480 720" })
```
Then `hyprctl reload && hyprctl configerrors` — expected: no errors. If `center`/`size` are rejected, use `move = "center"` per the error text and re-validate.

- [ ] **Step 2: Dependencies** — `bin/omarchy-globalprotect-install-deps` (polkit prompt). Then `bin/omarchy-globalprotect deps` → all true; `pacman -Ql openconnect | grep hipreport` to confirm the HIP script path matches `HIP_SCRIPTS`.
- [ ] **Step 3: README** — sections: what it is, screenshot placeholder, install (`omarchy plugin add … --enable --yes`, install deps button), first run (portal, Google window, HIP/clientOs notes), how it works (NM owns the tunnel; where secrets live; forget), keyboard shortcuts, troubleshooting (portal rejects Linux → clientOs; HIP; `journalctl -u NetworkManager`), development (`scripts/check`), license.
- [ ] **Step 4: Run `scripts/check`, commit** `docs: README, changelog, Hyprland window rule note`

---

## Self-review

- Spec coverage: decisions 1–13 → Tasks 4 (window), 5 (NM/keyring), 1 (manifest/settings), 9 (window rule, deps), 7 (monitor, notifications), 8 (panel/animations/keyboard). Real-portal verification remains a manual first-run step (documented in README).
- Placeholders: the README "screenshot placeholder" is a documentation image slot, not code; everything else is concrete.
- Type consistency: `phase=` names (`preparing`, `signing-in`, `authenticating`, `activating`, `connected`) match between `cmd_connect` and `connectProc`; exit codes 0/1/2/3 match; status JSON keys match `Model.normalizeStatus`; `keyring_has` stub in Task 3 is replaced in Task 5.
