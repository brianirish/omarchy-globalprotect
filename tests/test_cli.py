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
        # nmcli reports the *base* device as IP-IFACE for VPN connections; the tunnel device is the one holding the VPN address.
        details = "GENERAL.STATE:activated\nGENERAL.IP-IFACE:enp7s0\nIP4.ADDRESS[1]:10.1.2.3/32\nconnection.timestamp:1757490000\n"
        with tempfile.TemporaryDirectory() as d, unittest.mock.patch.dict(os.environ, {"XDG_STATE_HOME": d, "XDG_RUNTIME_DIR": d}):
            gp.save_state(gateway="gw.example.com", username="b@x.com")
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
            gp.save_state(gateway="gw.example.com", gatewayIp="68.111.1.18")
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
            iface, pre = gp.pick_prelogin("p", "Windows", "auto")
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
