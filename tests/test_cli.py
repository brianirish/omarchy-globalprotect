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
        pre = gp.parse_prelogin(xml)
        self.assertEqual((pre["method"], pre["request"], pre["defaultBrowser"]), ("POST", "<html></html>", False))

    def test_saml_default_browser_flag(self):
        xml = ("<prelogin-response><saml-auth-method>REDIRECT</saml-auth-method><saml-request>aHR0cHM6Ly9pZHAvc3Nv</saml-request>"
               "<saml-default-browser>yes</saml-default-browser></prelogin-response>")
        self.assertTrue(gp.parse_prelogin(xml)["defaultBrowser"])

    def test_redirect_method(self):
        xml = "<prelogin-response><saml-auth-method>REDIRECT</saml-auth-method><saml-request>aHR0cHM6Ly9pZHAvc3Nv</saml-request></prelogin-response>"
        self.assertEqual(gp.parse_prelogin(xml)["request"], "https://idp/sso")

    def test_error_status_raises_with_message(self):
        xml = "<prelogin-response><status>Error</status><msg>Valid client certificate is required</msg></prelogin-response>"
        with self.assertRaises(gp.PreloginError) as cm:
            gp.parse_prelogin(xml)
        self.assertIn("client certificate", str(cm.exception))

    def test_missing_saml_means_password_auth_with_labels(self):
        xml = ("<prelogin-response><status>Success</status><authentication-message>Enter login credentials</authentication-message>"
               "<username-label>Corp ID</username-label><password-label>Passcode</password-label></prelogin-response>")
        pre = gp.parse_prelogin(xml)
        self.assertEqual(pre["method"], "PASSWORD")
        self.assertEqual((pre["usernameLabel"], pre["passwordLabel"], pre["message"]), ("Corp ID", "Passcode", "Enter login credentials"))

    def test_missing_saml_and_labels_defaults_password_labels(self):
        pre = gp.parse_prelogin("<prelogin-response><status>Success</status></prelogin-response>")
        self.assertEqual((pre["method"], pre["usernameLabel"], pre["passwordLabel"]), ("PASSWORD", "Username", "Password"))

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
        # nmcli reports the *base* device as IP-IFACE for VPN connections; the tunnel device is the one holding the VPN address.
        details = "GENERAL.STATE:activated\nGENERAL.IP-IFACE:enp7s0\nIP4.ADDRESS[1]:10.1.2.3/32\nconnection.timestamp:1757490000\n"
        with tempfile.TemporaryDirectory() as d, unittest.mock.patch.dict(os.environ, {"XDG_STATE_HOME": d, "XDG_RUNTIME_DIR": d}):
            gp.save_state(portal="vpn.example.com", gateway="gw.example.com", username="b@x.com")
            with unittest.mock.patch.object(gp, "check_deps", return_value={"openconnect": True, "nmOpenconnect": True, "webkit": True}), \
                 unittest.mock.patch.object(gp, "nm_connection_state", return_value="activated"), \
                 unittest.mock.patch.object(gp, "nm_connection_details", return_value=gp.parse_nmcli_terse(details)), \
                 unittest.mock.patch.object(gp, "find_iface_for_ip", return_value="vpn0"), \
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

    def test_connected_reports_tunnel_details(self):
        details = (
            "GENERAL.STATE:activated\nIP4.ADDRESS[1]:10.1.2.3/32\nconnection.timestamp:1757490000\n"
            "IP4.ROUTE[1]:dst = 0.0.0.0/0, nh = 0.0.0.0, mt = 50\nIP4.DNS[1]:10.0.0.53\nIP4.DOMAIN[1]:corp.example.com\n"
        )
        with tempfile.TemporaryDirectory() as d, unittest.mock.patch.dict(os.environ, {"XDG_STATE_HOME": d, "XDG_RUNTIME_DIR": d}):
            gp.save_state(portal="vpn.example.com", gateway="gw.example.com", gatewayIp="68.111.1.18")
            with unittest.mock.patch.object(gp, "check_deps", return_value={"openconnect": True, "nmOpenconnect": True, "webkit": True}), \
                 unittest.mock.patch.object(gp, "nm_connection_state", return_value="activated"), \
                 unittest.mock.patch.object(gp, "nm_connection_details", return_value=gp.parse_nmcli_terse(details)), \
                 unittest.mock.patch.object(gp, "find_iface_for_ip", return_value="vpn0"), \
                 unittest.mock.patch.object(gp, "iface_stats", return_value=(0, 0)), \
                 unittest.mock.patch.object(gp, "socket_peers", return_value=[("udp", "68.111.1.18", 4501)]), \
                 unittest.mock.patch.object(gp, "keyring_has", return_value=False):
                s = gp.status_json("vpn.example.com")
        self.assertEqual(s["protocol"], "esp")
        self.assertEqual(s["gatewayIp"], "68.111.1.18")
        self.assertEqual(s["routes"], ["0.0.0.0/0"])
        self.assertTrue(s["fullTunnel"])
        self.assertEqual(s["dns"], ["10.0.0.53"])
        self.assertEqual(s["searchDomains"], ["corp.example.com"])

    def test_status_reports_nm_connectivity(self):
        with tempfile.TemporaryDirectory() as d, unittest.mock.patch.dict(os.environ, {"XDG_STATE_HOME": d, "XDG_RUNTIME_DIR": d}):
            with unittest.mock.patch.object(gp, "check_deps", return_value={"openconnect": True, "nmOpenconnect": True, "webkit": True}), \
                 unittest.mock.patch.object(gp, "nm_connection_state", return_value="inactive"), \
                 unittest.mock.patch.object(gp, "nm_connectivity", return_value="portal"), \
                 unittest.mock.patch.object(gp, "keyring_has", return_value=False):
                s = gp.status_json("vpn.example.com")
        self.assertEqual(s["connectivity"], "portal")

    def test_parse_connectivity_normalizes_values(self):
        self.assertEqual(gp.parse_connectivity("full\n"), "full")
        self.assertEqual(gp.parse_connectivity("portal"), "portal")
        self.assertEqual(gp.parse_connectivity("limited"), "limited")
        self.assertEqual(gp.parse_connectivity("none"), "none")
        self.assertEqual(gp.parse_connectivity("weird"), "unknown")
        self.assertEqual(gp.parse_connectivity(""), "unknown")

    def test_unconfigured_has_empty_tunnel_details(self):
        with tempfile.TemporaryDirectory() as d, unittest.mock.patch.dict(os.environ, {"XDG_STATE_HOME": d, "XDG_RUNTIME_DIR": d}):
            with unittest.mock.patch.object(gp, "check_deps", return_value={"openconnect": True, "nmOpenconnect": True, "webkit": True}):
                s = gp.status_json("")
        self.assertEqual((s["protocol"], s["gatewayIp"], s["routes"], s["fullTunnel"], s["dns"], s["searchDomains"]), ("", "", [], False, [], []))


class ConnectionDetailTests(unittest.TestCase):
    SS = (
        "udp ESTAB      0      960           192.168.68.65:54579     68.111.1.18:4501\n"
        "udp ESTAB      0      0            192.168.250.17:58033   160.79.104.10:443\n"
        "tcp ESTAB      0      0            192.168.250.17:41234   140.82.112.3:443\n"
        "tcp LISTEN     0      128                 0.0.0.0:22           0.0.0.0:*\n"
    )

    def test_parse_ss_peers_keeps_established_peers(self):
        peers = gp.parse_ss_peers(self.SS)
        self.assertIn(("udp", "68.111.1.18", 4501), peers)
        self.assertIn(("tcp", "140.82.112.3", 443), peers)
        self.assertNotIn(("tcp", "0.0.0.0", 0), peers)
        self.assertEqual(len(peers), 3)

    def test_parse_ss_peers_handles_ipv6_brackets(self):
        peers = gp.parse_ss_peers("tcp ESTAB 0 0 [2001:db8::1]:5000 [2001:db8::2]:443\n")
        self.assertEqual(peers, [("tcp", "2001:db8::2", 443)])

    def test_protocol_esp_when_udp_4501_to_gateway(self):
        self.assertEqual(gp.detect_protocol(gp.parse_ss_peers(self.SS), "68.111.1.18"), "esp")

    def test_protocol_ssl_when_only_tcp_443_to_gateway(self):
        peers = [("tcp", "68.111.1.18", 443), ("udp", "1.2.3.4", 4501)]
        self.assertEqual(gp.detect_protocol(peers, "68.111.1.18"), "ssl")

    def test_protocol_unknown_without_matching_peer(self):
        self.assertEqual(gp.detect_protocol([("tcp", "9.9.9.9", 443)], "68.111.1.18"), "")

    def test_protocol_falls_back_to_any_esp_port_when_gateway_ip_unknown(self):
        self.assertEqual(gp.detect_protocol(gp.parse_ss_peers(self.SS), ""), "esp")
        self.assertEqual(gp.detect_protocol([("tcp", "9.9.9.9", 443)], ""), "")

    DETAILS = gp.parse_nmcli_terse(
        "IP4.ADDRESS[1]:192.168.250.17/32\n"
        "IP4.ROUTE[1]:dst = 1.1.1.1/32, nh = 0.0.0.0, mt = 50\n"
        "IP4.ROUTE[2]:dst = 0.0.0.0/0, nh = 0.0.0.0, mt = 50\n"
        "IP4.DNS[1]:10.0.0.53\n"
        "IP4.DNS[2]:10.0.0.54\n"
        "IP4.DOMAIN[1]:corp.example.com\n"
    )

    def test_nm_list_orders_indexed_fields(self):
        self.assertEqual(gp.nm_list(self.DETAILS, "IP4.DNS"), ["10.0.0.53", "10.0.0.54"])
        self.assertEqual(gp.nm_list(self.DETAILS, "IP4.DOMAIN"), ["corp.example.com"])
        self.assertEqual(gp.nm_list(self.DETAILS, "IP6.DNS"), [])

    def test_nm_routes_extracts_destinations(self):
        self.assertEqual(gp.nm_routes(self.DETAILS), ["1.1.1.1/32", "0.0.0.0/0"])

    def test_full_tunnel_when_default_route_present(self):
        self.assertTrue(gp.is_full_tunnel(["1.1.1.1/32", "0.0.0.0/0"]))
        self.assertFalse(gp.is_full_tunnel(["10.0.0.0/8", "172.16.0.0/12"]))
        self.assertFalse(gp.is_full_tunnel([]))


class HipReportTests(unittest.TestCase):
    XML = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<hip-report name="hip-report">\n'
        '  <md5-sum>0</md5-sum><user-name>b@x.com</user-name><domain></domain>\n'
        '  <host-name>dz-linux</host-name><host-id>deadbeef-dead-beef-dead-beefdeadbeef</host-id>\n'
        '  <ip-address>10.1.2.3</ip-address><ipv6-address></ipv6-address>\n'
        '  <generate-time>09/10/2026 12:00:00</generate-time><hip-report-version>4</hip-report-version>\n'
        '  <categories>\n'
        '    <entry name="host-info">\n'
        '      <client-version>5.1.5-8</client-version><os>Microsoft Windows 10 Pro , 64-bit</os>\n'
        '      <os-vendor>Microsoft</os-vendor><domain>.internal</domain>\n'
        '      <host-name>dz-linux</host-name><host-id>deadbeef-dead-beef-dead-beefdeadbeef</host-id>\n'
        '    </entry>\n'
        '    <entry name="anti-malware"><list/></entry>\n'
        '    <entry name="disk-encryption"><list/></entry>\n'
        '  </categories>\n'
        '</hip-report>\n'
    )

    def test_parse_extracts_host_info(self):
        r = gp.parse_hip_report(self.XML)
        self.assertEqual(r["os"], "Microsoft Windows 10 Pro , 64-bit")
        self.assertEqual(r["osVendor"], "Microsoft")
        self.assertEqual(r["clientVersion"], "5.1.5-8")
        self.assertEqual(r["hostName"], "dz-linux")
        self.assertEqual(r["hostId"], "deadbeef-dead-beef-dead-beefdeadbeef")
        self.assertEqual(r["ipAddress"], "10.1.2.3")
        self.assertEqual(r["categories"], ["host-info", "anti-malware", "disk-encryption"])
        self.assertEqual(r["products"], [])

    def test_parse_lists_claimed_products(self):
        xml = self.XML.replace(
            '<entry name="anti-malware"><list/></entry>',
            '<entry name="antivirus"><list><entry><ProductInfo><Prod name="McAfee VirusScan Enterprise" version="8.8"/></ProductInfo></entry>'
            '<entry><ProductInfo><Prod name="Windows Defender" version="4.11"/></ProductInfo></entry></list></entry>'
            '<entry name="anti-spyware"><list><entry><ProductInfo><Prod name="Windows Defender" version="4.11"/></ProductInfo></entry></list></entry>')
        self.assertEqual(gp.parse_hip_report(xml)["products"], ["McAfee VirusScan Enterprise", "Windows Defender"])

    def test_parse_missing_host_info_gives_empty_strings(self):
        r = gp.parse_hip_report('<hip-report><categories/></hip-report>')
        self.assertEqual((r["os"], r["clientVersion"], r["categories"]), ("", "", []))

    def test_parse_bad_xml_raises(self):
        with self.assertRaises(gp.HipError):
            gp.parse_hip_report("<nope")

    def test_command_passes_identity_and_os(self):
        cmd = gp.hip_report_command("/usr/lib/openconnect/hipreport.sh", "b@x.com", "dz-linux", "10.1.2.3", "win")
        self.assertEqual(cmd[0], "/usr/lib/openconnect/hipreport.sh")
        cookie = cmd[cmd.index("--cookie") + 1]
        self.assertIn("user=b@x.com", cookie)
        self.assertIn("computer=dz-linux", cookie)
        self.assertEqual(cmd[cmd.index("--client-ip") + 1], "10.1.2.3")
        self.assertEqual(cmd[cmd.index("--client-os") + 1], "Windows")
        self.assertEqual(len(cmd[cmd.index("--md5") + 1]), 32)

    def test_command_uses_placeholder_ip_when_disconnected(self):
        cmd = gp.hip_report_command("/s", "u", "h", "", "linux")
        self.assertEqual(cmd[cmd.index("--client-ip") + 1], "0.0.0.0")
        self.assertEqual(cmd[cmd.index("--client-os") + 1], "Linux")


class LogBundleTests(unittest.TestCase):
    def test_scrub_masks_cookie_values_in_every_shape(self):
        text = (
            "COOKIE='user=b@x.com&authcookie=abc123&portal=p'\n"
            "vpn.secrets.cookie:deadbeefcafe\n"
            "<prelogin-cookie>SECRETVALUE</prelogin-cookie>\n"
            "<portal-userauthcookie>OTHERSECRET</portal-userauthcookie>\n"
            "prelogin-cookie=abc&user=me\n"
            "password: hunter2\n"
        )
        out = gp.scrub_secrets(text)
        for secret in ("abc123", "deadbeefcafe", "SECRETVALUE", "OTHERSECRET", "hunter2"):
            self.assertNotIn(secret, out)
        self.assertNotIn("prelogin-cookie=abc", out)
        self.assertIn("user=b@x.com", out)
        self.assertIn("portal=p", out)

    def test_scrub_leaves_ordinary_text_alone(self):
        text = "phase=connected\nESP session established with server\nCookie policy unchanged\n"
        self.assertEqual(gp.scrub_secrets(text), text)

    def test_debug_log_writes_only_when_enabled(self):
        with tempfile.TemporaryDirectory() as d, unittest.mock.patch.dict(os.environ, {"XDG_STATE_HOME": d}):
            gp.set_debug(False)
            gp.debug_log("silent")
            self.assertFalse((pathlib.Path(d) / "omarchy-globalprotect" / "debug.log").exists())
            gp.set_debug(True)
            try:
                gp.debug_log("hello world")
            finally:
                gp.set_debug(False)
            log = (pathlib.Path(d) / "omarchy-globalprotect" / "debug.log").read_text()
        self.assertIn("hello world", log)
        self.assertRegex(log, r"^\d{4}-\d{2}-\d{2}T")

    def test_debug_log_rotates_when_large(self):
        with tempfile.TemporaryDirectory() as d, unittest.mock.patch.dict(os.environ, {"XDG_STATE_HOME": d}):
            logdir = pathlib.Path(d) / "omarchy-globalprotect"
            logdir.mkdir()
            (logdir / "debug.log").write_text("x" * (gp.DEBUG_LOG_MAX + 1))
            gp.set_debug(True)
            try:
                gp.debug_log("fresh")
            finally:
                gp.set_debug(False)
            self.assertTrue((logdir / "debug.log.1").exists())
            self.assertIn("fresh", (logdir / "debug.log").read_text())
            self.assertLess((logdir / "debug.log").stat().st_size, 200)

    def test_bundle_path_is_timestamped(self):
        import datetime
        when = datetime.datetime(2026, 9, 10, 12, 34, 56)
        self.assertEqual(gp.bundle_path(pathlib.Path("/tmp/x"), when), pathlib.Path("/tmp/x/omarchy-globalprotect-logs-20260910-123456.tar.gz"))

    def test_write_bundle_creates_private_tarball_with_members(self):
        import tarfile
        with tempfile.TemporaryDirectory() as d:
            path = pathlib.Path(d) / "bundle.tar.gz"
            gp.write_bundle(path, {"status.json": "{}", "journal.txt": "line\n"})
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            with tarfile.open(path) as tar:
                names = sorted(tar.getnames())
                self.assertEqual(names, sorted(["omarchy-globalprotect-logs/journal.txt", "omarchy-globalprotect-logs/status.json"]))
                self.assertEqual(tar.extractfile("omarchy-globalprotect-logs/journal.txt").read(), b"line\n")


class PortalConfigTests(unittest.TestCase):
    XML = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<policy><portal-name>corp</portal-name>\n'
        '  <portal-userauthcookie>PUAC</portal-userauthcookie>\n'
        '  <gateways><cutoff-time>5</cutoff-time><external><list>\n'
        '    <entry name="gw-east.example.com:443"><priority>1</priority><manual>no</manual><description>US East</description></entry>\n'
        '    <entry name="gw-west.example.com"><priority-rule><entry name="Any"><priority>2</priority></entry></priority-rule>\n'
        '      <manual>yes</manual><description>US West</description></entry>\n'
        '    <entry name="gw-eu.example.com:443"><description>EU</description></entry>\n'
        '  </list></external></gateways>\n'
        '  <hip-collection><hip-report-interval>60</hip-report-interval></hip-collection>\n'
        '</policy>\n'
    )

    def test_parse_lists_gateways_with_host_priority_and_manual(self):
        cfg = gp.parse_portal_config(self.XML)
        names = [g["name"] for g in cfg["gateways"]]
        self.assertEqual(names, ["gw-east.example.com:443", "gw-west.example.com", "gw-eu.example.com:443"])
        east, west, eu = cfg["gateways"]
        self.assertEqual((east["host"], east["description"], east["priority"], east["manual"]), ("gw-east.example.com", "US East", 1, False))
        self.assertEqual((west["host"], west["priority"], west["manual"]), ("gw-west.example.com", 2, True))
        self.assertEqual((eu["host"], eu["description"], eu["priority"], eu["manual"]), ("gw-eu.example.com", "EU", 0, False))

    def test_parse_returns_portal_cookie_and_hip_interval(self):
        cfg = gp.parse_portal_config(self.XML)
        self.assertEqual(cfg["portalUserAuthCookie"], "PUAC")
        self.assertEqual(cfg["hipInterval"], 60)

    def test_parse_no_gateways_gives_empty_list(self):
        cfg = gp.parse_portal_config("<policy><gateways/></policy>")
        self.assertEqual(cfg["gateways"], [])

    def test_parse_bad_xml_raises(self):
        with self.assertRaises(gp.PortalConfigError):
            gp.parse_portal_config("<policy")

    def test_parse_error_status_raises_with_message(self):
        with self.assertRaises(gp.PortalConfigError) as cm:
            gp.parse_portal_config("<prelogin-response><status>Error</status><msg>Invalid username or password</msg></prelogin-response>")
        self.assertIn("Invalid username", str(cm.exception))

    def test_config_body_carries_identity_and_prelogin_cookie(self):
        body = gp.portal_config_body("vpn.example.com", "b@x.com", "COOKIE123", "win", "dz-linux")
        fields = dict(pair.split("=", 1) for pair in body.split("&"))
        self.assertEqual(fields["user"], "b%40x.com")
        self.assertEqual(fields["prelogin-cookie"], "COOKIE123")
        self.assertEqual(fields["server"], "vpn.example.com")
        self.assertEqual(fields["computer"], "dz-linux")
        self.assertEqual(fields["clientos"], "Windows")
        for key in ("jnlpReady", "ok", "direct", "clientVer", "prot", "ipv6-support", "os-version"):
            self.assertIn(key, fields)
        self.assertNotIn("passwd", fields)

    GWS = [
        {"name": "a:443", "host": "a", "description": "A", "priority": 2, "manual": False},
        {"name": "b", "host": "b", "description": "B", "priority": 1, "manual": False},
        {"name": "c", "host": "c", "description": "C", "priority": 1, "manual": False},
        {"name": "m", "host": "m", "description": "M", "priority": 1, "manual": True},
    ]

    def test_best_gateway_prefers_priority_then_latency(self):
        self.assertEqual(gp.best_gateway(self.GWS, {"a": 5, "b": 80, "c": 40, "m": 1}), "c")

    def test_best_gateway_unknown_latency_loses_to_measured(self):
        self.assertEqual(gp.best_gateway(self.GWS, {"b": 80}), "b")

    def test_best_gateway_skips_manual_only_and_handles_empty(self):
        self.assertEqual(gp.best_gateway([self.GWS[3]], {"m": 1}), "")
        self.assertEqual(gp.best_gateway([], {}), "")

    def test_best_gateway_unknown_priority_ranks_last(self):
        gws = [{"name": "x", "host": "x", "description": "", "priority": 0, "manual": False}] + self.GWS[:1]
        self.assertEqual(gp.best_gateway(gws, {"x": 1, "a": 500}), "a:443")

    def test_gateway_host_strips_port(self):
        self.assertEqual(gp.gateway_host("gw.example.com:443"), "gw.example.com")
        self.assertEqual(gp.gateway_host("gw.example.com"), "gw.example.com")
        self.assertEqual(gp.gateway_host(""), "")

    def test_signin_host_uses_gateway_for_gateway_interface_only(self):
        self.assertEqual(gp.signin_host("portal.example.com", "gateway", "gw.example.com:443"), "gw.example.com")
        self.assertEqual(gp.signin_host("portal.example.com", "portal", "gw.example.com:443"), "portal.example.com")
        self.assertEqual(gp.signin_host("portal.example.com", "gateway", ""), "portal.example.com")

    def test_resolve_gateway_choice_prefers_explicit_then_best(self):
        state = {"gateways": self.GWS, "latencies": {"b": 80, "c": 40}}
        self.assertEqual(gp.resolve_gateway_choice("a:443", state), "a:443")
        self.assertEqual(gp.resolve_gateway_choice("", state), "c")
        self.assertEqual(gp.resolve_gateway_choice("", {}), "")


class SignInOptionTests(unittest.TestCase):
    def test_authenticate_command_password_mode_has_no_cookie_kind(self):
        cmd = gp.authenticate_command("p", None, "u", "win", "", None, interface="gateway")
        self.assertIn("--usergroup=gateway", cmd)
        self.assertNotIn("--usergroup=gateway:", " ".join(cmd))
        self.assertIn("--passwd-on-stdin", cmd)

    def test_authenticate_command_passes_proxy_and_certificate(self):
        cmd = gp.authenticate_command("p", "prelogin-cookie", "u", "win", "", None, interface="gateway",
                                      proxy="http://proxy.corp:3128", certificate="/c.pem", key="/k.pem")
        self.assertIn("--proxy=http://proxy.corp:3128", cmd)
        self.assertIn("--certificate=/c.pem", cmd)
        self.assertIn("--sslkey=/k.pem", cmd)
        self.assertEqual(cmd[-1], "p")

    def test_authenticate_command_omits_options_when_empty(self):
        cmd = gp.authenticate_command("p", "prelogin-cookie", "u", "win", "", None)
        self.assertFalse(any(a.startswith(("--proxy", "--certificate", "--sslkey")) for a in cmd))

    def test_vpn_data_carries_proxy_and_certificate(self):
        data = gp.build_vpn_data("p", False, None, proxy="http://proxy.corp:3128", certificate="/c.pem", key="/k.pem")
        self.assertIn("proxy=http://proxy.corp:3128", data)
        self.assertIn("usercert=/c.pem", data)
        self.assertIn("privkey=/k.pem", data)
        self.assertNotIn("proxy", gp.build_vpn_data("p", False, None))

    def test_prompt_pending_detects_an_unanswered_prompt(self):
        self.assertEqual(gp.prompt_pending("POST https://gw/ssl-vpn/login.esp\nPassword:"), "Password:")
        self.assertEqual(gp.prompt_pending("Challenge: Enter the code from your token\nResponse: "), "Response:")
        self.assertEqual(gp.prompt_pending("Some log line\n"), "")
        self.assertEqual(gp.prompt_pending(""), "")
        self.assertEqual(gp.prompt_pending("COOKIE='abc'\nHOST='1.2.3.4'\n"), "")

    def test_prompt_pending_ignores_openconnect_progress_lines(self):
        self.assertEqual(gp.prompt_pending("Connected to 1.2.3.4:443\nSSL negotiation with gw\nConnected to HTTPS on gw with ciphersuite X\n"), "")

    def test_parse_callback_uri_extracts_user_and_token(self):
        r = gp.parse_callback_uri("globalprotectcallback:cas-as=1&un=b%40x.com&token=TOK123")
        self.assertEqual(r, {"username": "b@x.com", "token": "TOK123"})

    def test_parse_callback_uri_rejects_other_schemes(self):
        with self.assertRaises(gp.AuthError):
            gp.parse_callback_uri("https://example.com/?un=x&token=y")
        with self.assertRaises(gp.AuthError):
            gp.parse_callback_uri("globalprotectcallback:cas-as=1&un=x")

    def test_credential_keyring_attrs_are_scoped_to_portal_and_user(self):
        attrs = gp._credential_attrs("vpn.example.com", "b@x.com")
        self.assertIn("application", attrs)
        self.assertIn("vpn.example.com", attrs)
        self.assertIn("b@x.com", attrs)
        self.assertEqual(attrs[attrs.index("kind") + 1], "password")


class InteractiveAuthTests(unittest.TestCase):
    """authenticate_interactive drives openconnect through a pty: password first, any later prompt via the callback."""

    FAKE = (
        "#!/usr/bin/env python3\n"
        "import sys\n"
        "sys.stdout.write('POST https://gw/ssl-vpn/login.esp\\n'); sys.stdout.flush()\n"
        "sys.stdout.write('Password:'); sys.stdout.flush()\n"
        "pw = sys.stdin.readline().rstrip('\\n')\n"
        "if pw != 'hunter2':\n"
        "    sys.stdout.write('\\nLogin failed\\n'); sys.exit(1)\n"
        "sys.stdout.write('\\nChallenge: Enter the code from your token\\nResponse: '); sys.stdout.flush()\n"
        "code = sys.stdin.readline().rstrip('\\n')\n"
        "if code != '123456':\n"
        "    sys.stdout.write('\\nBad code\\n'); sys.exit(1)\n"
        "sys.stdout.write(\"\\nCOOKIE='user=u&authcookie=abc'\\nHOST='1.2.3.4'\\nCONNECT_URL='https://gw/'\\nFINGERPRINT='pin-sha256:xyz'\\n\")\n"
    )

    def _fake(self, d):
        path = pathlib.Path(d) / "openconnect"
        path.write_text(self.FAKE)
        path.chmod(0o755)
        return str(path)

    def test_answers_password_then_routes_challenge_to_callback(self):
        seen = []
        with tempfile.TemporaryDirectory() as d:
            auth = gp.authenticate_interactive("gw", "u", "hunter2", "win", "", None, "gateway",
                                               lambda prompt, context="": (seen.append(prompt), "123456")[1], openconnect_bin=self._fake(d), timeout=20)
        self.assertEqual(auth["COOKIE"], "user=u&authcookie=abc")
        self.assertEqual(auth["FINGERPRINT"], "pin-sha256:xyz")
        self.assertEqual(seen, ["Response:"])

    def test_wrong_password_raises_with_last_line(self):
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(gp.AuthError) as cm:
                gp.authenticate_interactive("gw", "u", "nope", "win", "", None, "gateway", lambda p, c="": "x", openconnect_bin=self._fake(d), timeout=20)
        self.assertIn("Login failed", str(cm.exception))

    def test_cancel_from_callback_propagates(self):
        def cancel(prompt, context=""):
            raise gp.Cancelled("Sign-in cancelled")
        with tempfile.TemporaryDirectory() as d:
            with self.assertRaises(gp.Cancelled):
                gp.authenticate_interactive("gw", "u", "hunter2", "win", "", None, "gateway", cancel, openconnect_bin=self._fake(d), timeout=20)


class NetworkOptionTests(unittest.TestCase):
    def test_vpn_data_ssl_only_and_mtu(self):
        data = gp.build_vpn_data("p", False, None, ssl_only=True, mtu=1400)
        self.assertIn("disable_udp=yes", data)
        self.assertIn("mtu=1400", data)
        plain = gp.build_vpn_data("p", False, None)
        self.assertNotIn("disable_udp", plain)
        self.assertNotIn("mtu=", plain)
        self.assertNotIn("mtu=", gp.build_vpn_data("p", False, None, mtu=0))

    ROUTES = [
        {"dst": "default", "dev": "vpn0", "protocol": "static", "scope": "link", "metric": 50},
        {"dst": "default", "gateway": "192.168.68.1", "dev": "enp7s0", "protocol": "dhcp", "metric": 100},
        {"dst": "1.1.1.1", "dev": "vpn0", "protocol": "static", "scope": "link", "metric": 50},
        {"dst": "68.111.1.18", "dev": "enp7s0", "protocol": "static", "metric": 50},
        {"dst": "192.168.68.0/22", "dev": "enp7s0", "protocol": "kernel", "scope": "link", "metric": 100},
        {"dst": "192.168.68.1", "dev": "enp7s0", "protocol": "static", "scope": "link", "metric": 50},
        {"dst": "10.20.0.0/16", "dev": "wlp6s0", "protocol": "kernel", "scope": "link", "metric": 600},
        {"dst": "172.17.0.0/16", "dev": "docker0", "protocol": "kernel", "scope": "link", "metric": 0},
    ]

    def test_lan_subnets_are_kernel_link_routes_on_real_devices(self):
        self.assertEqual(gp.lan_subnets(self.ROUTES, "vpn0"), ["192.168.68.0/22", "10.20.0.0/16"])

    def test_lan_subnets_ignores_tunnel_and_host_routes(self):
        routes = [{"dst": "10.1.2.0/24", "dev": "vpn0", "protocol": "kernel", "scope": "link"},
                  {"dst": "192.168.1.5", "dev": "enp7s0", "protocol": "kernel", "scope": "link"}]
        self.assertEqual(gp.lan_subnets(routes, "vpn0"), [])

    RESOLVECTL = (
        "Link 4 (vpn0)\n"
        "    Current Scopes: DNS\n"
        "         Protocols: -DefaultRoute -LLMNR -mDNS DNSOverTLS=opportunistic\n"
        "                    DNSSEC=no/unsupported\n"
        "Current DNS Server: 10.0.0.53\n"
        "       DNS Servers: 10.0.0.53 10.0.0.54\n"
        "        DNS Domain: ~corp.example.com ~lab.example.com\n"
    )

    def test_parse_resolvectl_link_reads_servers_and_domains(self):
        r = gp.parse_resolvectl_link(self.RESOLVECTL)
        self.assertEqual(r["dns"], ["10.0.0.53", "10.0.0.54"])
        self.assertEqual(r["domains"], ["~corp.example.com", "~lab.example.com"])
        self.assertTrue(r["active"])
        self.assertFalse(r["defaultRoute"])

    def test_parse_resolvectl_link_handles_no_scopes(self):
        r = gp.parse_resolvectl_link("Link 4 (vpn0)\n    Current Scopes: none\n     Default Route: no\n")
        self.assertEqual((r["dns"], r["domains"], r["active"]), ([], [], False))

    def test_parse_resolvectl_default_route_yes(self):
        text = "Link 4 (vpn0)\n    Current Scopes: DNS\n         Protocols: +DefaultRoute\n       DNS Servers: 10.0.0.53\n        DNS Domain: ~.\n"
        self.assertTrue(gp.parse_resolvectl_link(text)["defaultRoute"])

    def test_split_dns_rule_grants_resolved_link_actions_to_local_wheel(self):
        text = gp.split_dns_rule()
        for action in ("org.freedesktop.resolve1.set-dns-servers", "org.freedesktop.resolve1.set-domains", "org.freedesktop.resolve1.set-default-route"):
            self.assertIn(action, text)
        self.assertIn('isInGroup("wheel")', text)
        self.assertIn("subject.local", text)

    def test_split_dns_state_from_files(self):
        with tempfile.TemporaryDirectory() as conf, tempfile.TemporaryDirectory() as rules:
            conf, rules = pathlib.Path(conf), pathlib.Path(rules)
            self.assertEqual(gp.split_dns_state(conf, rules), "not-needed")
            (conf / "20-omarchy-dns.conf").write_text("[global-dns]\n\n[global-dns-domain-*]\nservers=1.1.1.1\n")
            self.assertEqual(gp.split_dns_state(conf, rules), "needed")
            (rules / gp.SPLIT_DNS_RULE_FILE).write_text(gp.split_dns_rule())
            self.assertEqual(gp.split_dns_state(conf, rules), "enabled")

    def test_split_dns_plan_routes_pushed_domains_only(self):
        plan = gp.split_dns_plan("vpn0", ["10.0.0.53"], ["corp.example.com", "lab.example.com"], True, "auto")
        self.assertEqual(plan, [
            ["resolvectl", "dns", "vpn0", "10.0.0.53"],
            ["resolvectl", "domain", "vpn0", "~corp.example.com", "~lab.example.com"],
            ["resolvectl", "default-route", "vpn0", "no"],
        ])

    def test_split_dns_plan_full_tunnel_without_domains_takes_all_dns_in_auto(self):
        plan = gp.split_dns_plan("vpn0", ["10.0.0.53"], [], True, "auto")
        self.assertEqual(plan[1], ["resolvectl", "domain", "vpn0", "~."])
        self.assertEqual(plan[2], ["resolvectl", "default-route", "vpn0", "yes"])

    def test_split_dns_plan_is_empty_when_off_or_nothing_to_route(self):
        self.assertEqual(gp.split_dns_plan("vpn0", ["10.0.0.53"], ["corp.example.com"], True, "off"), [])
        self.assertEqual(gp.split_dns_plan("vpn0", [], ["corp.example.com"], True, "auto"), [])
        self.assertEqual(gp.split_dns_plan("vpn0", ["10.0.0.53"], [], False, "auto"), [])
        self.assertEqual(gp.split_dns_plan("vpn0", ["10.0.0.53"], [], True, "split"), [])

    def test_global_ip6_skips_link_local(self):
        details = gp.parse_nmcli_terse("IP6.ADDRESS[1]:fe80::1/64\nIP6.ADDRESS[2]:2001:db8::5/128\n")
        self.assertEqual(gp.global_ip6(details), "2001:db8::5")
        self.assertEqual(gp.global_ip6(gp.parse_nmcli_terse("IP6.ADDRESS[1]:fe80::1/64\n")), "")


class PortalPolicyTests(unittest.TestCase):
    XML = (
        '<policy><portal-name>Client-VPN</portal-name><version>6.1.1-5</version>'
        '<connect-method>user-logon</connect-method><on-demand>no</on-demand>'
        '<refresh-config>yes</refresh-config><refresh-config-interval>24</refresh-config-interval>'
        '<config-digest>4e0f27c0</config-digest>'
        '<agent-config><rediscover-network>yes</rediscover-network><enable-signout>yes</enable-signout>'
        '<default-browser>yes</default-browser><retry-tunnel>30</retry-tunnel><retry-timeout>5</retry-timeout>'
        '<captive-portal-notification-delay>5</captive-portal-notification-delay><ssl-only-selection>0</ssl-only-selection>'
        '<tunnel-mtu>1400</tunnel-mtu><save-user-credentials>1</save-user-credentials></agent-config>'
        '<agent-ui><can-save-password>yes</can-save-password><can-change-portal>yes</can-change-portal>'
        '<welcome-page><display>yes</display><page>&lt;h1&gt;Welcome&lt;/h1&gt;</page></welcome-page>'
        '<help-page><display>no</display><page></page></help-page></agent-ui>'
        '<hip-collection><hip-report-interval>3600</hip-report-interval></hip-collection>'
        '<gateways><external><list><entry name="gw"><description>GW</description></entry></list></external></gateways>'
        '</policy>'
    )

    def test_policy_fields(self):
        pol = gp.parse_portal_config(self.XML)["policy"]
        self.assertEqual(pol["connectMethod"], "user-logon")
        self.assertEqual(pol["refreshConfigInterval"], 24)
        self.assertEqual(pol["configDigest"], "4e0f27c0")
        self.assertEqual(pol["tunnelMtu"], 1400)
        self.assertFalse(pol["sslOnly"])
        self.assertTrue(pol["rediscoverNetwork"])
        self.assertTrue(pol["enableSignout"])
        self.assertTrue(pol["defaultBrowser"])
        self.assertEqual((pol["retryTunnel"], pol["retryTimeout"]), (30, 5))
        self.assertEqual(pol["captivePortalNotificationDelay"], 5)
        self.assertTrue(pol["canSavePassword"])
        self.assertTrue(pol["canChangePortal"])
        self.assertEqual(pol["welcomePage"], "<h1>Welcome</h1>")
        self.assertEqual(pol["version"], "6.1.1-5")

    def test_policy_defaults_when_absent(self):
        pol = gp.parse_portal_config("<policy><gateways/></policy>")["policy"]
        self.assertEqual(pol["connectMethod"], "")
        self.assertEqual(pol["tunnelMtu"], 0)
        self.assertEqual(pol["welcomePage"], "")
        self.assertTrue(pol["rediscoverNetwork"])
        self.assertTrue(pol["enableSignout"])

    def test_ssl_only_selection_one_means_ssl_only(self):
        pol = gp.parse_portal_config("<policy><agent-config><ssl-only-selection>1</ssl-only-selection></agent-config></policy>")["policy"]
        self.assertTrue(pol["sslOnly"])

    def test_welcome_page_hidden_when_display_no(self):
        xml = self.XML.replace("<welcome-page><display>yes</display>", "<welcome-page><display>no</display>")
        self.assertEqual(gp.parse_portal_config(xml)["policy"]["welcomePage"], "")

    def test_config_body_with_portal_cookie_instead_of_prelogin(self):
        body = gp.portal_config_body("vpn.example.com", "b@x.com", "", "win", "dz-linux", userauthcookie="PUAC")
        fields = dict(pair.split("=", 1) for pair in body.split("&"))
        self.assertEqual(fields["portal-userauthcookie"], "PUAC")
        self.assertNotIn("prelogin-cookie", fields)
        self.assertNotIn("passwd", fields)


class HipJournalTests(unittest.TestCase):
    LINES = (
        "2026-09-10T10:16:09-0700 dz-linux NetworkManager[75564]: POST https://gw/ssl-vpn/hipreportcheck.esp\n"
        "2026-09-10T10:16:09-0700 dz-linux NetworkManager[75564]: WARNING: Server asked us to submit HIP report with md5sum 0f51.\n"
        "2026-09-10T10:16:10-0700 dz-linux NetworkManager[75564]: Submitting HIP report\n"
        "2026-09-10T10:16:10-0700 dz-linux NetworkManager[75564]: HIP report submitted successfully\n"
        "2026-09-10T11:16:09-0700 dz-linux openconnect[75564]: GlobalProtect HIP check due\n"
        "2026-09-10T11:16:09-0700 dz-linux openconnect[75564]: POST https://gw/ssl-vpn/hipreportcheck.esp\n"
    )

    def test_parses_last_check_and_submit(self):
        h = gp.parse_hip_journal(self.LINES)
        self.assertEqual(h["lastCheck"], "2026-09-10T11:16:09-0700")
        self.assertEqual(h["lastSubmit"], "2026-09-10T10:16:10-0700")
        self.assertEqual(h["warning"], "")

    def test_surfaces_failure_lines_as_warning(self):
        lines = self.LINES + "2026-09-10T12:16:09-0700 dz-linux openconnect[75564]: HIP report submission failed: Compliance check failed\n"
        h = gp.parse_hip_journal(lines)
        self.assertIn("Compliance check failed", h["warning"])
        self.assertEqual(h["warningAt"], "2026-09-10T12:16:09-0700")

    def test_empty_journal(self):
        self.assertEqual(gp.parse_hip_journal("")["lastCheck"], "")


class PerPortalStateTests(unittest.TestCase):
    def test_state_is_scoped_per_portal_with_a_global_current_portal(self):
        with tempfile.TemporaryDirectory() as d, unittest.mock.patch.dict(os.environ, {"XDG_STATE_HOME": d}):
            gp.save_state(portal="a.example.com", username="ua", gateway="ga")
            gp.save_state(portal="b.example.com", username="ub")
            s = gp.load_state()
            self.assertEqual((s["portal"], s["username"]), ("b.example.com", "ub"))
            self.assertNotIn("gateway", s)
            self.assertEqual(gp.load_state("a.example.com")["gateway"], "ga")
            gp.save_state(portal="a.example.com")
            self.assertEqual(gp.load_state()["username"], "ua")
            self.assertEqual(gp.known_portals(), ["a.example.com", "b.example.com"])

    def test_save_without_portal_targets_the_current_one(self):
        with tempfile.TemporaryDirectory() as d, unittest.mock.patch.dict(os.environ, {"XDG_STATE_HOME": d}):
            gp.save_state(portal="a.example.com")
            gp.save_state(username="ua")
            self.assertEqual(gp.load_state("a.example.com")["username"], "ua")

    def test_forget_portal_drops_only_that_portal(self):
        with tempfile.TemporaryDirectory() as d, unittest.mock.patch.dict(os.environ, {"XDG_STATE_HOME": d}):
            gp.save_state(portal="a.example.com", username="ua")
            gp.save_state(portal="b.example.com", username="ub")
            gp.forget_portal("a.example.com")
            self.assertEqual(gp.known_portals(), ["b.example.com"])
            self.assertEqual(gp.load_state("b.example.com")["username"], "ub")


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


class AuthInterfaceTests(unittest.TestCase):
    def test_pick_prelogin_signs_in_at_the_chosen_gateway_host(self):
        seen = []

        def fake_prelogin(host, client_os, timeout=20, interface="portal"):
            seen.append((host, interface))
            return {"method": "REDIRECT", "request": "https://idp/sso"}

        with unittest.mock.patch.object(gp, "prelogin", side_effect=fake_prelogin):
            iface, host, pre = gp.pick_prelogin("portal.example.com", "Windows", "gateway", gateway="gw-east.example.com:443")
        self.assertEqual((iface, host), ("gateway", "gw-east.example.com"))
        self.assertEqual(seen, [("gw-east.example.com", "gateway")])

    def test_prelogin_urls(self):
        self.assertEqual(gp.prelogin_url("vpn.example.com", "portal"), "https://vpn.example.com/global-protect/prelogin.esp")
        self.assertEqual(gp.prelogin_url("vpn.example.com", "gateway"), "https://vpn.example.com/ssl-vpn/prelogin.esp")

    def test_gateway_interface_command(self):
        cmd = gp.authenticate_command("vpn.example.com", "prelogin-cookie", "b@x.com", "win", "GW-EU", None, interface="gateway")
        self.assertIn("--usergroup=gateway:prelogin-cookie", cmd)
        self.assertNotIn("--authgroup=GW-EU", cmd)  # gateway selection is a portal concept

    def test_portal_interface_is_default(self):
        self.assertIn("--usergroup=portal:prelogin-cookie", gp.authenticate_command("p", "prelogin-cookie", "u", "win", "", None))

    def test_interface_order(self):
        self.assertEqual(gp.interfaces_to_try("auto"), ["gateway", "portal"])
        self.assertEqual(gp.interfaces_to_try("portal"), ["portal"])
        self.assertEqual(gp.interfaces_to_try("gateway"), ["gateway"])
        self.assertEqual(gp.interfaces_to_try("nonsense"), ["gateway", "portal"])

    def test_pick_prelogin_falls_back_to_portal(self):
        calls = []
        def fake_prelogin(portal, client_os, timeout=20, interface="portal"):
            calls.append(interface)
            if interface == "gateway":
                raise gp.PreloginError("no saml here")
            return {"method": "REDIRECT", "request": "https://idp/sso"}
        with unittest.mock.patch.object(gp, "prelogin", fake_prelogin):
            iface, host, pre = gp.pick_prelogin("p", "Windows", "auto")
        self.assertEqual(host, "p")
        self.assertEqual((iface, pre["method"], calls), ("portal", "REDIRECT", ["gateway", "portal"]))

    def test_pick_prelogin_raises_last_error_when_all_fail(self):
        def fake_prelogin(portal, client_os, timeout=20, interface="portal"):
            raise gp.PreloginError(f"{interface} failed")
        with unittest.mock.patch.object(gp, "prelogin", fake_prelogin):
            with self.assertRaises(gp.PreloginError) as cm:
                gp.pick_prelogin("p", "Windows", "auto")
        self.assertIn("portal failed", str(cm.exception))


class NmProfileCommandTests(unittest.TestCase):
    # nm-openconnect refuses "private" (user-permission-scoped) connections, so the
    # profile must stay a system connection.
    def test_add_command_has_no_user_permissions(self):
        cmd = gp.nm_profile_command(False, "gateway=p,protocol=gp")
        self.assertEqual(cmd[:4], ["nmcli", "connection", "add", "type"])
        self.assertNotIn("connection.permissions", cmd)
        self.assertEqual(cmd[-2:], ["vpn.data", "gateway=p,protocol=gp"])

    # A link change (Wi-Fi roam, cable swap, suspend) must not make NetworkManager
    # tear the tunnel down; openconnect reconnects with the same cookie instead.
    def test_add_command_makes_profile_persistent(self):
        cmd = gp.nm_profile_command(False, "gateway=p,protocol=gp")
        i = cmd.index("vpn.persistent")
        self.assertEqual(cmd[i + 1], "yes")

    def test_modify_command_makes_profile_persistent(self):
        cmd = gp.nm_profile_command(True, "gateway=p,protocol=gp")
        i = cmd.index("vpn.persistent")
        self.assertEqual(cmd[i + 1], "yes")

    def test_modify_command_clears_permissions(self):
        cmd = gp.nm_profile_command(True, "gateway=p,protocol=gp")
        self.assertEqual(cmd[:4], ["nmcli", "connection", "modify", "GlobalProtect"])
        i = cmd.index("connection.permissions")
        self.assertEqual(cmd[i + 1], "")
