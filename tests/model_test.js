// Unit tests for Model.js (the panel's pure helpers). Run with: node tests/model_test.js
// Model.js starts with QML's ".pragma library" line, which plain JS rejects, so it is
// loaded through vm with that line stripped.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

// Its top-level functions and vars become properties of the context object.
const src = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8").replace(/^\.pragma library\s*$/m, "");
const Model = {};
vm.runInNewContext(src, Model);
const { tr } = require(path.join(__dirname, "tr.js"));
const en = tr("en");
// Bengali digits stand in for a language whose numbers aren't ASCII.
const digits = (v, decimals) => (decimals === undefined ? String(v) : Number(v).toFixed(decimals)).replace(/[0-9]/g, (d) => "০১২৩৪৫৬৭৮৯"[d]);

let passed = 0;
function test(name, fn) {
  try { fn(); passed++; console.log("ok   " + name); }
  catch (e) { console.log("FAIL " + name + "\n     " + (e && e.message)); process.exitCode = 1; }
}

const base = { alwaysOn: true, restore: false, configured: true, depsOk: true, state: "disconnected",
               connectivity: "full", pausedUntil: 0, now: 100000, nextAttemptAt: 0, inFlight: false };

test("connects when always-on, idle, online, not paused", () => {
  assert.equal(Model.autoConnectDecision(base).action, "connect");
});
test("does nothing when neither always-on nor restoring", () => {
  assert.equal(Model.autoConnectDecision({ ...base, alwaysOn: false }).action, "none");
});
test("restore alone is enough to reconnect", () => {
  assert.equal(Model.autoConnectDecision({ ...base, alwaysOn: false, restore: true }).action, "connect");
});
test("does nothing while connected or transitioning or in flight", () => {
  for (const state of ["connected", "authenticating", "activating"])
    assert.equal(Model.autoConnectDecision({ ...base, state }).action, "none", state);
  assert.equal(Model.autoConnectDecision({ ...base, inFlight: true }).action, "none");
});
test("does nothing when unconfigured or deps missing", () => {
  assert.equal(Model.autoConnectDecision({ ...base, configured: false }).action, "none");
  assert.equal(Model.autoConnectDecision({ ...base, depsOk: false }).action, "none");
});
test("paused wins over everything else", () => {
  const d = Model.autoConnectDecision({ ...base, pausedUntil: base.now + 1 });
  assert.equal(d.action, "none");
  assert.equal(d.reason, "paused");
});
test("captive portal waits with its own reason", () => {
  const d = Model.autoConnectDecision({ ...base, connectivity: "portal" });
  assert.deepEqual([d.action, d.reason], ["wait", "captive"]);
});
test("offline or limited waits", () => {
  for (const c of ["none", "limited"])
    assert.deepEqual([Model.autoConnectDecision({ ...base, connectivity: c }).action, Model.autoConnectDecision({ ...base, connectivity: c }).reason], ["wait", "offline"], c);
});
test("unknown connectivity is treated as online", () => {
  assert.equal(Model.autoConnectDecision({ ...base, connectivity: "unknown" }).action, "connect");
});
test("backoff not yet elapsed waits", () => {
  const d = Model.autoConnectDecision({ ...base, nextAttemptAt: base.now + 500 });
  assert.deepEqual([d.action, d.reason], ["wait", "backoff"]);
});
test("error state is retried like disconnected", () => {
  assert.equal(Model.autoConnectDecision({ ...base, state: "error" }).action, "connect");
});
test("a user switch-off in progress blocks auto-connect", () => {
  assert.equal(Model.autoConnectDecision({ ...base, userOff: true }).action, "none");
});
test("autoText describes each waiting reason", () => {
  assert.match(Model.autoText("paused", Date.parse("2026-09-10T13:05:00"), 0, 0, en), /13:05/);
  assert.match(Model.autoText("captive", 0, 0, 0, en), /Captive portal/);
  assert.match(Model.autoText("offline", 0, 0, 0, en), /network/);
  assert.equal(Model.autoText("backoff", 0, 100000 + 4200, 100000, en), "Retrying in 5s");
  assert.equal(Model.autoText("backoff", 0, 100000 + 120000, 100000, en), "Retrying in 2m 00s");
  assert.equal(Model.autoText("", 0, 0, 0, en), "");
});
test("autoText takes the clock and digits it is given", () => {
  const clock = { time: () => "1:05 PM", dateTime: () => "" };
  assert.equal(Model.autoText("paused", 0, 0, 0, en, digits, clock), "Always-On paused until 1:05 PM");
  assert.equal(Model.autoText("backoff", 0, 100000 + 4200, 100000, en, digits), "Retrying in ৫s");
});
test("normalizeStatus carries connectivity with an unknown fallback", () => {
  assert.equal(Model.normalizeStatus({ connectivity: "portal" }).connectivity, "portal");
  assert.equal(Model.normalizeStatus({ connectivity: "bogus" }).connectivity, "unknown");
  assert.equal(Model.normalizeStatus({}).connectivity, "unknown");
});
test("routesText and dnsText summarize what the gateway pushed", () => {
  assert.equal(Model.routesText(["0.0.0.0/0", "1.1.1.1/32"], true, en), "Full tunnel");
  assert.equal(Model.routesText(["10.0.0.0/8"], false, en), "Split · 10.0.0.0/8");
  assert.equal(Model.routesText([], false, en), "—");
  assert.equal(Model.dnsText(["10.0.0.53"], ["corp.example.com"]), "10.0.0.53 · corp.example.com");
  assert.equal(Model.dnsText([], []), "—");
});
test("policyChanges maps the portal's agent-config onto settings", () => {
  // Objects born inside the vm context have a different Object prototype, so compare by JSON.
  const same = (a, b) => assert.equal(JSON.stringify(a), JSON.stringify(b));
  const policy = Model.normalizePolicy({ connectMethod: "user-logon", tunnelMtu: 1400, sslOnly: false });
  same(Model.policyChanges(policy, { connectMethod: "on-demand", mtu: 0, sslOnly: false }), { connectMethod: "always-on", mtu: 1400 });
  same(Model.policyChanges(policy, { connectMethod: "always-on", mtu: 1400, sslOnly: false }), {});
  same(Model.policyChanges(Model.normalizePolicy({ connectMethod: "on-demand", sslOnly: true }), { connectMethod: "always-on", mtu: 0, sslOnly: false }), { connectMethod: "on-demand", sslOnly: true });
  same(Model.policyChanges(Model.normalizePolicy({}), { connectMethod: "on-demand", mtu: 0, sslOnly: false }), {});
});
test("resolverText prefers what resolved uses over what was pushed", () => {
  assert.equal(Model.resolverText({ dns: ["10.0.0.53"], domains: ["~corp.example.com"], active: true, defaultRoute: false }, ["1.1.1.1"], [], "enabled", en), "10.0.0.53 · ~corp.example.com");
  assert.equal(Model.resolverText({ dns: ["10.0.0.53"], domains: ["~."], active: true, defaultRoute: true }, [], [], "enabled", en), "10.0.0.53 · all queries");
  assert.equal(Model.resolverText({ dns: [], domains: [], active: false, defaultRoute: false }, ["1.1.1.1"], [], "needed", en), "1.1.1.1 · not applied");
  assert.equal(Model.resolverText({ dns: [], domains: [], active: false, defaultRoute: false }, ["1.1.1.1"], [], "enabled", en), "1.1.1.1 · idle");
  assert.equal(Model.resolverText({ dns: [], domains: [], active: false, defaultRoute: false }, [], [], "needed", en), "—");
});
test("backoff doubles from 30 s and caps at 10 min", () => {
  assert.equal(Model.nextBackoffMs(1), 30000);
  assert.equal(Model.nextBackoffMs(2), 60000);
  assert.equal(Model.nextBackoffMs(3), 120000);
  assert.equal(Model.nextBackoffMs(10), 600000);
  assert.equal(Model.nextBackoffMs(0), 30000);
});

// A connected -> not-connected transition is "not our doing" only when nothing
// of ours explains it. The user's switch-off intent must be read as it was when
// the status was sampled: the bug was resetting it one line before asking.
const drop = { previous: "connected", state: "disconnected", disconnecting: false, userOff: false, reconnectPending: false };
test("an external drop is detected", () => {
  assert.equal(Model.tunnelDropped(drop), true);
  assert.equal(Model.tunnelDropped({ ...drop, state: "error" }), true);
});
test("a user switch-off is never treated as an external drop", () => {
  assert.equal(Model.tunnelDropped({ ...drop, userOff: true }), false);
});
test("a disconnect in flight or a pending reconnect is not a drop", () => {
  assert.equal(Model.tunnelDropped({ ...drop, disconnecting: true }), false);
  assert.equal(Model.tunnelDropped({ ...drop, reconnectPending: true }), false);
});
test("no transition means no drop", () => {
  assert.equal(Model.tunnelDropped({ ...drop, previous: "disconnected" }), false);
  assert.equal(Model.tunnelDropped({ ...drop, state: "connected" }), false);
  assert.equal(Model.tunnelDropped({ ...drop, previous: "" }), false);
});

// A status poll that straddles one of our own transitions can report the state
// from before it: "disconnected" while our connect is still running, or
// "connected" after our disconnect finished. Both are ignored.
test("a stale disconnected snapshot during our connect is ignored", () => {
  assert.equal(Model.snapshotIsStale({ state: "disconnected", connecting: true, disconnecting: false, userOff: false }), true);
  assert.equal(Model.snapshotIsStale({ state: "connected", connecting: true, disconnecting: false, userOff: false }), false);
});
test("a stale connected snapshot during or right after our disconnect is ignored", () => {
  assert.equal(Model.snapshotIsStale({ state: "connected", connecting: false, disconnecting: true, userOff: true }), true);
  assert.equal(Model.snapshotIsStale({ state: "connected", connecting: false, disconnecting: false, userOff: true }), true);
  assert.equal(Model.snapshotIsStale({ state: "disconnected", connecting: false, disconnecting: false, userOff: true }), false);
});
test("an idle poll is never stale", () => {
  for (const state of ["connected", "disconnected", "error"])
    assert.equal(Model.snapshotIsStale({ state, connecting: false, disconnecting: false, userOff: false }), false, state);
});

test("normalizeStatus carries the shared switch-off intent and pause", () => {
  assert.equal(Model.normalizeStatus({ userOff: true, pausedUntil: 5000 }).userOff, true);
  assert.equal(Model.normalizeStatus({ userOff: true, pausedUntil: 5000 }).pausedUntil, 5000);
  assert.equal(Model.normalizeStatus({}).userOff, false);
  assert.equal(Model.normalizeStatus({}).pausedUntil, 0);
});

// One bar per screen means one widget per screen; only the one on the first
// screen acts on shared events (notifications, restoration, Always-On).
test("the widget on the first screen is the leader", () => {
  assert.equal(Model.isLeader("DP-1", ["DP-1", "DP-3"]), true);
  assert.equal(Model.isLeader("DP-3", ["DP-1", "DP-3"]), false);
});
test("a lone or unknown screen always leads", () => {
  assert.equal(Model.isLeader("DP-3", ["DP-3"]), true);
  assert.equal(Model.isLeader("", ["DP-1", "DP-3"]), true);
  assert.equal(Model.isLeader("DP-1", []), true);
  assert.equal(Model.isLeader("DP-1", null), true);
});

// The panel shows the installed version next to its title, read from manifest.json.
test("manifestVersion reads the version and tolerates garbage", () => {
  assert.equal(Model.manifestVersion('{"id": "x", "version": "1.0.5"}'), "1.0.5");
  assert.equal(Model.manifestVersion('{"id": "x"}'), "");
  assert.equal(Model.manifestVersion("not json"), "");
  assert.equal(Model.manifestVersion(""), "");
});

// Boolean settings: `omarchy bar set` without --json stores "true"/"false" strings.
test("flag reads booleans and the strings omarchy bar set stores", () => {
  assert.equal(Model.flag(true, false), true);
  assert.equal(Model.flag("true", false), true);
  assert.equal(Model.flag(false, true), false);
  assert.equal(Model.flag("false", true), false);
});
test("flag falls back for anything else", () => {
  for (const v of [undefined, null, "", "yes", 1, 0])
    assert.equal(Model.flag(v, true), true, String(v));
});

// Text: every state, phrase and row reads from the catalog.
test("stateText words every state, and the missing package is named verbatim", () => {
  assert.equal(Model.stateText("unconfigured", en), "Set a portal to get started");
  assert.equal(Model.stateText("missing-deps", en), "Needs networkmanager-openconnect");
  assert.equal(Model.stateText("authenticating", en), "Signing in…");
  assert.equal(Model.stateText("activating", en), "Bringing the tunnel up…");
  assert.equal(Model.stateText("connected", en), "Connected");
  assert.equal(Model.stateText("error", en), "Something went wrong");
  assert.equal(Model.stateText("disconnected", en), "Disconnected");
  assert.equal(Model.stateText("anything else", en), "Disconnected");
});
test("phraseText cycles through every phrase and wraps", () => {
  const seen = new Set();
  for (let i = 0; i < Model.PHRASE_COUNT; i++) seen.add(Model.phraseText(i, en));
  assert.equal(seen.size, Model.PHRASE_COUNT);
  for (const p of seen) assert.ok(!p.startsWith("phrase."), p + " is a bare key");
  assert.equal(Model.phraseText(0, en), "Tunnel sealed");
  assert.equal(Model.phraseText(Model.PHRASE_COUNT, en), "Tunnel sealed");
  assert.equal(Model.phraseText(-1, en), Model.phraseText(Model.PHRASE_COUNT - 1, en));
});
test("tunnelText names the negotiated protocol", () => {
  assert.equal(Model.tunnelText("esp", en), "IPSec · ESP over UDP");
  assert.equal(Model.tunnelText("ssl", en), "SSL · TCP 443");
  assert.equal(Model.tunnelText("", en), "—");
});
test("host state rows", () => {
  const h = Model.normalizeHostState({ enabled: true, report: { os: "Windows", clientVersion: "6.2.1", hostName: "box", hostId: "id-1", products: [] } });
  assert.equal(Model.reportsAsText(h, en), "Windows · client 6.2.1");
  assert.equal(Model.reportsAsText({ ...h, clientVersion: "" }, en), "Windows");
  assert.equal(Model.claimsText(h, en), "Host info only");
  assert.equal(Model.claimsText({ ...h, products: ["AV", "Firewall"] }, en), "AV, Firewall");
  assert.equal(Model.hostText(h), "box · id-1");
});
test("formatDuration pads minutes and seconds", () => {
  assert.equal(Model.formatDuration(7, en), "7s");
  assert.equal(Model.formatDuration(65, en), "1m 05s");
  assert.equal(Model.formatDuration(3600 + 9 * 60 + 30, en), "1h 09m");
  assert.equal(Model.formatDuration(-3, en), "0s");
});
test("formatDuration and formatBytesPerSec write numbers through formatNumber", () => {
  assert.equal(Model.formatDuration(65, en, digits), "১m ০৫s");
  assert.equal(Model.formatBytesPerSec(512, digits), "৫১২ B/s");
  assert.equal(Model.formatBytesPerSec(2048, digits), "২.০ KB/s");
});
test("formatBytesPerSec keeps its units and decimals", () => {
  assert.equal(Model.formatBytesPerSec(512), "512 B/s");
  assert.equal(Model.formatBytesPerSec(2048), "2.0 KB/s");
  assert.equal(Model.formatBytesPerSec(20480), "20 KB/s");
  assert.equal(Model.formatBytesPerSec(3 * 1024 * 1024), "3.0 MB/s");
  // A decimal comma, as Danish has it.
  const comma = (v, d) => (d === undefined ? String(v) : Number(v).toFixed(d)).replace(".", ",");
  assert.equal(Model.formatBytesPerSec(2048, comma), "2,0 KB/s");
});
test("gatewayMeta joins host, priority, manual and latency", () => {
  const g = { host: "gw1.example.com", description: "East", priority: 1, manual: true, latencyMs: 23 };
  assert.equal(Model.gatewayMeta(g, en), "gw1.example.com · P1 · manual · 23 ms");
  assert.equal(Model.gatewayMeta({ ...g, manual: false, latencyMs: -1 }, en), "gw1.example.com · P1 · unreachable");
  assert.equal(Model.gatewayMeta({ ...g, host: "East", priority: 0, manual: false, latencyMs: -2 }, en), "");
  assert.equal(Model.gatewayMeta(g, en, digits), "gw1.example.com · P১ · manual · ২৩ ms");
});
test("timestampText shows the time today and the date and time otherwise", () => {
  const clock = { time: () => "TIME", dateTime: () => "DATE TIME" };
  const now = Date.parse("2026-11-09T15:00:00");
  assert.equal(Model.timestampText("2026-11-09T09:30:00", clock, now), "TIME");
  assert.equal(Model.timestampText("2026-11-08T09:30:00", clock, now), "DATE TIME");
  assert.equal(Model.timestampText("", clock, now), "—");
  assert.equal(Model.timestampText("not a date", clock, now), "not a date");
  assert.equal(Model.timestampText("2026-11-09T09:30:00", undefined, now), "09:30");
});

// Data from the portal, the gateway and NetworkManager is shown verbatim
// (the panel's Text elements are all plain text), and a value that looks
// like a placeholder is never filled in again.
test("markup- and placeholder-shaped data passes through verbatim", () => {
  const sneaky = '<img src="https://example.invalid/t">';
  assert.equal(Model.routesText([sneaky], false, en), "Split · " + sneaky);
  assert.equal(Model.gatewayMeta({ host: sneaky, description: "x", priority: 0, manual: false, latencyMs: -2 }, en), sneaky);
  assert.equal(Model.fill("%1 · client %2", ["%2", "6.2"]), "%2 · client 6.2");
});
test("a language without a catalog falls back to English", () => {
  // "xx" has no i18n/xx.json, so every lookup reaches en.json.
  assert.equal(Model.stateText("connected", tr("xx")), "Connected");
});
test("a translated catalog is used when it has the string", () => {
  assert.notEqual(Model.stateText("connected", tr("da")), "Connected");
});

console.log(passed + " passed");
