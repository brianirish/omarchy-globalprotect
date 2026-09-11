// Unit tests for Model.js (the panel's pure helpers). Run with: node tests/model_test.js
// Model.js starts with QML's ".pragma library" line, which plain JS rejects, so it is
// loaded through vm with that line stripped.
"use strict";
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const src = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8").replace(/^\.pragma library\s*$/m, "");
const M = {};
vm.runInNewContext(src + "\nthis.__exports = { autoConnectDecision: typeof autoConnectDecision === 'function' ? autoConnectDecision : undefined, nextBackoffMs: typeof nextBackoffMs === 'function' ? nextBackoffMs : undefined, autoText: typeof autoText === 'function' ? autoText : undefined, tunnelDropped: typeof tunnelDropped === 'function' ? tunnelDropped : undefined, snapshotIsStale: typeof snapshotIsStale === 'function' ? snapshotIsStale : undefined, normalizeStatus, routesText, dnsText, gatewayMeta, policyChanges: typeof policyChanges === 'function' ? policyChanges : undefined, normalizePolicy: typeof normalizePolicy === 'function' ? normalizePolicy : undefined, resolverText: typeof resolverText === 'function' ? resolverText : undefined };", M);
const Model = M.__exports;

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
  assert.match(Model.autoText("paused", Date.parse("2026-09-10T13:05:00"), 0, 0), /13:05/);
  assert.match(Model.autoText("captive", 0, 0, 0), /Captive portal/);
  assert.match(Model.autoText("offline", 0, 0, 0), /network/);
  assert.equal(Model.autoText("backoff", 0, 100000 + 4200, 100000), "Retrying in 5s");
  assert.equal(Model.autoText("", 0, 0, 0), "");
});
test("normalizeStatus carries connectivity with an unknown fallback", () => {
  assert.equal(Model.normalizeStatus({ connectivity: "portal" }).connectivity, "portal");
  assert.equal(Model.normalizeStatus({ connectivity: "bogus" }).connectivity, "unknown");
  assert.equal(Model.normalizeStatus({}).connectivity, "unknown");
});
test("routesText and dnsText summarize what the gateway pushed", () => {
  assert.equal(Model.routesText(["0.0.0.0/0", "1.1.1.1/32"], true), "Full tunnel");
  assert.equal(Model.routesText(["10.0.0.0/8"], false), "Split · 10.0.0.0/8");
  assert.equal(Model.routesText([], false), "—");
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
  assert.equal(Model.resolverText({ dns: ["10.0.0.53"], domains: ["~corp.example.com"], active: true, defaultRoute: false }, ["1.1.1.1"], [], "enabled"), "10.0.0.53 · ~corp.example.com");
  assert.equal(Model.resolverText({ dns: ["10.0.0.53"], domains: ["~."], active: true, defaultRoute: true }, [], [], "enabled"), "10.0.0.53 · all queries");
  assert.equal(Model.resolverText({ dns: [], domains: [], active: false, defaultRoute: false }, ["1.1.1.1"], [], "needed"), "1.1.1.1 · not applied");
  assert.equal(Model.resolverText({ dns: [], domains: [], active: false, defaultRoute: false }, [], [], "needed"), "—");
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

console.log(passed + " passed");
