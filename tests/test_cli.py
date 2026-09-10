"""Unit tests for the pure helpers in bin/omarchy-globalprotect."""
import importlib.machinery
import importlib.util
import os
import pathlib
import tempfile
import unittest
import unittest.mock

CLI = pathlib.Path(__file__).resolve().parents[1] / "bin" / "omarchy-globalprotect"
# The CLI has no .py suffix, so name the loader explicitly.
spec = importlib.util.spec_from_loader("gpcli", importlib.machinery.SourceFileLoader("gpcli", str(CLI)))
gp = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gp)


class PreloginTests(unittest.TestCase):
    def test_post_method_decodes_request(self):
        xml = "<prelogin-response><status>Success</status><saml-auth-method>POST</saml-auth-method><saml-request>PGh0bWw+PC9odG1sPg==</saml-request></prelogin-response>"
        self.assertEqual(gp.parse_prelogin(xml), {"method": "POST", "request": "<html></html>"})

    def test_redirect_method(self):
        xml = "<prelogin-response><saml-auth-method>REDIRECT</saml-auth-method><saml-request>aHR0cHM6Ly9pZHAvc3Nv</saml-request></prelogin-response>"
        self.assertEqual(gp.parse_prelogin(xml)["request"], "https://idp/sso")

    def test_error_status_raises_with_message(self):
        xml = "<prelogin-response><status>Error</status><msg>Valid client certificate is required</msg></prelogin-response>"
        with self.assertRaises(gp.PreloginError) as cm:
            gp.parse_prelogin(xml)
        self.assertIn("client certificate", str(cm.exception))

    def test_missing_saml_raises(self):
        with self.assertRaises(gp.PreloginError):
            gp.parse_prelogin("<prelogin-response><status>Success</status></prelogin-response>")

    def test_unparseable_xml_raises(self):
        with self.assertRaises(gp.PreloginError):
            gp.parse_prelogin("<html>not xml at all")


class SamlResultTests(unittest.TestCase):
    def test_headers_win(self):
        r = gp.extract_saml_result({"Prelogin-Cookie": "abc", "saml-username": "b@x.com", "content-type": "text/html"}, None)
        self.assertEqual(r, {"prelogin-cookie": "abc", "saml-username": "b@x.com"})

    def test_html_comment(self):
        html = "<html><!-- <saml-auth-status>1</saml-auth-status><prelogin-cookie>zzz</prelogin-cookie><saml-username>b@x.com</saml-username><saml-slo>no</saml-slo> --></html>"
        r = gp.extract_saml_result(None, html)
        self.assertEqual(r["prelogin-cookie"], "zzz")
        self.assertEqual(r["saml-username"], "b@x.com")
        self.assertEqual(r["saml-auth-status"], "1")

    def test_headers_take_precedence_over_html(self):
        r = gp.extract_saml_result({"prelogin-cookie": "fromheader"}, "<!-- <prelogin-cookie>fromhtml</prelogin-cookie> -->")
        self.assertEqual(r["prelogin-cookie"], "fromheader")

    def test_complete_requires_username_and_cookie(self):
        self.assertFalse(gp.saml_result_complete({"saml-username": "u"}))
        self.assertFalse(gp.saml_result_complete({"prelogin-cookie": "c"}))
        self.assertTrue(gp.saml_result_complete({"saml-username": "u", "portal-userauthcookie": "c"}))

    def test_choose_cookie_prefers_prelogin(self):
        self.assertEqual(gp.choose_cookie({"prelogin-cookie": "p", "portal-userauthcookie": "u"}), ("prelogin-cookie", "p"))
        self.assertEqual(gp.choose_cookie({"portal-userauthcookie": "u"}), ("portal-userauthcookie", "u"))

    def test_choose_cookie_without_cookie_raises(self):
        with self.assertRaises(gp.AuthError):
            gp.choose_cookie({"saml-username": "u"})


class AuthenticateOutputTests(unittest.TestCase):
    def test_parses_quoted_values(self):
        text = "COOKIE='USER=b; AUTH=xyz'\nHOST='10.0.0.1'\nCONNECT_URL='https://gw.example.com/ssl-vpn/'\nFINGERPRINT='pin-sha256:AAAA'\n"
        a = gp.parse_authenticate_output(text)
        self.assertEqual(a["COOKIE"], "USER=b; AUTH=xyz")
        self.assertEqual(a["CONNECT_URL"], "https://gw.example.com/ssl-vpn/")
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
        self.assertEqual(
            gp.build_vpn_data("vpn.example.com", False, None),
            "gateway=vpn.example.com,protocol=gp,authtype=password,cookie-flags=2,gateway-flags=2,gwcert-flags=2,resolve-flags=2,enable_csd_trojan=no",
        )

    def test_with_hip(self):
        self.assertTrue(gp.build_vpn_data("p", True, "/usr/lib/openconnect/hipreport.sh").endswith("enable_csd_trojan=yes,csd_wrapper=/usr/lib/openconnect/hipreport.sh"))


class NmcliTerseTests(unittest.TestCase):
    def test_unescapes_colons(self):
        d = gp.parse_nmcli_terse("GENERAL.STATE:activated\nIP4.ADDRESS[1]:10.1.2.3/32\nVPN.BANNER:a\\:b\n")
        self.assertEqual(d["GENERAL.STATE"], "activated")
        self.assertEqual(d["IP4.ADDRESS[1]"], "10.1.2.3/32")
        self.assertEqual(d["VPN.BANNER"], "a:b")


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


class RunfileTests(unittest.TestCase):
    def test_dead_pid_reports_not_alive(self):
        with tempfile.TemporaryDirectory() as d, unittest.mock.patch.dict(os.environ, {"XDG_RUNTIME_DIR": d}):
            gp.write_runfile("signing-in", pid=999999)
            self.assertFalse(gp.read_runfile()["alive"])
            gp.clear_runfile()
            self.assertIsNone(gp.read_runfile())

    def test_live_pid(self):
        with tempfile.TemporaryDirectory() as d, unittest.mock.patch.dict(os.environ, {"XDG_RUNTIME_DIR": d}):
            gp.write_runfile("activating")
            rf = gp.read_runfile()
            self.assertTrue(rf["alive"])
            self.assertEqual(rf["phase"], "activating")


class StateFileTests(unittest.TestCase):
    def test_round_trip(self):
        with tempfile.TemporaryDirectory() as d, unittest.mock.patch.dict(os.environ, {"XDG_STATE_HOME": d}):
            gp.save_state(gateway="gw.example.com")
            gp.save_state(username="b@x.com")
            self.assertEqual(gp.load_state(), {"gateway": "gw.example.com", "username": "b@x.com"})

    def test_none_values_are_skipped(self):
        with tempfile.TemporaryDirectory() as d, unittest.mock.patch.dict(os.environ, {"XDG_STATE_HOME": d}):
            gp.save_state(gateway="gw", username=None)
            self.assertEqual(gp.load_state(), {"gateway": "gw"})

    def test_state_file_is_private(self):
        with tempfile.TemporaryDirectory() as d, unittest.mock.patch.dict(os.environ, {"XDG_STATE_HOME": d}):
            gp.save_state(portal="p")
            mode = (pathlib.Path(d) / gp.APP / "state.json").stat().st_mode & 0o777
            self.assertEqual(mode, 0o600)


class StatusJsonTests(unittest.TestCase):
    def test_unconfigured_shape(self):
        with tempfile.TemporaryDirectory() as d, unittest.mock.patch.dict(os.environ, {"XDG_STATE_HOME": d, "XDG_RUNTIME_DIR": d}):
            with unittest.mock.patch.object(gp, "check_deps", return_value={"openconnect": True, "nmOpenconnect": True, "webkit": True}):
                s = gp.status_json("")
        self.assertEqual(s["state"], "unconfigured")
        for key in ("portal", "gateway", "username", "hasSession", "iface", "ip4", "since", "rxBytes", "txBytes", "detail", "deps"):
            self.assertIn(key, s)

    def test_connected_reads_details(self):
        details = "GENERAL.STATE:activated\nGENERAL.IP-IFACE:vpn0\nIP4.ADDRESS[1]:10.1.2.3/32\nconnection.timestamp:1757490000\n"
        with tempfile.TemporaryDirectory() as d, unittest.mock.patch.dict(os.environ, {"XDG_STATE_HOME": d, "XDG_RUNTIME_DIR": d}):
            gp.save_state(gateway="gw.example.com", username="b@x.com")
            with unittest.mock.patch.object(gp, "check_deps", return_value={"openconnect": True, "nmOpenconnect": True, "webkit": True}), \
                 unittest.mock.patch.object(gp, "nm_connection_state", return_value="activated"), \
                 unittest.mock.patch.object(gp, "nm_connection_details", return_value=gp.parse_nmcli_terse(details)), \
                 unittest.mock.patch.object(gp, "iface_stats", return_value=(1234, 99)), \
                 unittest.mock.patch.object(gp, "keyring_has", return_value=True):
                s = gp.status_json("vpn.example.com")
        self.assertEqual(s["state"], "connected")
        self.assertEqual(s["iface"], "vpn0")
        self.assertEqual(s["ip4"], "10.1.2.3")
        self.assertEqual(s["since"], 1757490000)
        self.assertEqual((s["rxBytes"], s["txBytes"]), (1234, 99))
        self.assertEqual(s["gateway"], "gw.example.com")
        self.assertTrue(s["hasSession"])


class ThemeColorTests(unittest.TestCase):
    def test_parses_minimal_toml(self):
        c = gp.parse_theme_colors('mode = "dark"\naccent = "#7d82d9"\nbackground = "#060B1E"\nforeground = "#ffcead"\n')
        self.assertEqual(c, {"accent": "#7d82d9", "background": "#060B1E", "foreground": "#ffcead"})

    def test_defaults_when_missing(self):
        self.assertEqual(gp.parse_theme_colors("")["background"], "#101315")

    def test_ignores_non_hex_and_other_keys(self):
        c = gp.parse_theme_colors('background = "blue"\nred = "#ED5B5A"\n')
        self.assertEqual(c["background"], "#101315")
        self.assertNotIn("red", c)


class AuthenticateCommandTests(unittest.TestCase):
    def test_builds_portal_prelogin_command(self):
        cmd = gp.authenticate_command("vpn.example.com", "prelogin-cookie", "b@x.com", "win", "", None)
        self.assertEqual(cmd, ["openconnect", "--protocol=gp", "--authenticate", "--non-inter", "--os=win", "--user=b@x.com",
                               "--usergroup=portal:prelogin-cookie", "--passwd-on-stdin", "vpn.example.com"])

    def test_gateway_and_hip(self):
        cmd = gp.authenticate_command("p", "portal-userauthcookie", "u", "linux", "GW-EU", "/usr/lib/openconnect/hipreport.sh")
        self.assertIn("--authgroup=GW-EU", cmd)
        self.assertIn("--csd-wrapper=/usr/lib/openconnect/hipreport.sh", cmd)
        self.assertEqual(cmd[-1], "p")

    def test_cookie_never_in_argv(self):
        self.assertNotIn("SECRET", " ".join(gp.authenticate_command("p", "prelogin-cookie", "u", "win", "", None)))


class LastMeaningfulLineTests(unittest.TestCase):
    def test_skips_connection_chatter(self):
        text = "Connected to 1.2.3.4:443\nSSL negotiation with p\nConnected to HTTPS on p with ciphersuite X\nGetting login form\nFailed to obtain WebVPN cookie\n"
        self.assertEqual(gp.last_meaningful_line(text), "Failed to obtain WebVPN cookie")

    def test_empty(self):
        self.assertEqual(gp.last_meaningful_line(""), "")


if __name__ == "__main__":
    unittest.main()
