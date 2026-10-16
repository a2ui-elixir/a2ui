// Tests for priv/static/a2ui_phoenix.js: the openUrl listener and the
// A2UIMcpApp hook, run in a VM context with a stand-in browser.
import {test} from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import vm from "node:vm";

const source = readFileSync(new URL("../../priv/static/a2ui_phoenix.js", import.meta.url), "utf8");
const ORIGIN = "https://host.test";

// Values made inside the VM have its prototypes; compare them as JSON.
const plain = (value) => (value === undefined ? undefined : JSON.parse(JSON.stringify(value)));

function browser() {
  const listeners = {};
  const opened = [];
  const timers = [];
  const logged = [];
  const frameWindow = {
    posted: [],
    postMessage(message, origin) {
      this.posted.push({message, origin});
    },
  };
  const frame = {contentWindow: frameWindow, title: "", src: ""};

  const window = {
    location: {href: ORIGIN + "/page"},
    addEventListener(type, listener) {
      (listeners[type] ||= []).push(listener);
    },
    removeEventListener(type, listener) {
      listeners[type] = (listeners[type] || []).filter((other) => other !== listener);
    },
    open(...args) {
      opened.push(args);
    },
    matchMedia: () => ({matches: true}),
  };

  const context = vm.createContext({
    window,
    URL,
    TextEncoder,
    console: {log: (...args) => logged.push(args)},
    document: {createElement: () => frame},
    setTimeout(callback) {
      timers.push(callback);
      return timers.length;
    },
    clearTimeout() {},
  });

  vm.runInContext(source, context);
  return {window, listeners, opened, timers, logged, frame, frameWindow};
}

function mount(env, dataset = {}) {
  const container = {children: [], appendChild(child) { this.children.push(child); }};
  const pushed = [];
  const handlers = {};

  const el = {
    dataset: {
      sandbox: "/a2ui_phoenix/a2ui_mcp_sandbox.html",
      surface: "main",
      ref: "7",
      title: "Pong",
      html: "<p>Pong</p>",
      csp: '{"connectDomains":["https://api.test"]}',
      permissions: '{"camera":true}',
      state: JSON.stringify({score: {a: 1, b: 2}, toolInput: {level: 1}, toolResult: null, modelContext: "x"}),
      ...dataset,
    },
    style: {},
    querySelector: (selector) => (selector === "[data-a2ui-mcp-frame]" ? container : null),
    getBoundingClientRect: () => ({width: 300, height: 200}),
  };

  const hook = Object.assign(Object.create(env.window.A2UIPhoenix.hooks.A2UIMcpApp), {
    el,
    handleEvent(name, handler) {
      handlers[name] = handler;
    },
    pushEventTo(target, event, payload) {
      pushed.push({target, event, payload});
    },
  });

  hook.mounted();
  return {hook, el, container, pushed, handlers};
}

function fromApp(env, data, overrides = {}) {
  for (const listener of env.listeners.message || []) {
    listener({source: env.frameWindow, origin: ORIGIN, data, ...overrides});
  }
}

function posted(env) {
  const messages = env.frameWindow.posted.map((entry) => plain(entry.message));
  env.frameWindow.posted.length = 0;
  return messages;
}

function request(method, params, id = 1) {
  return {jsonrpc: "2.0", id, method, params};
}

function note(method, params = {}) {
  return {jsonrpc: "2.0", method, params};
}

test("openUrl events open http(s), mailto and tel links only", () => {
  const env = browser();
  const [listener] = env.listeners["phx:a2ui:open_url"];

  listener({detail: {url: "https://example.test/a"}});
  listener({detail: {url: "javascript:alert(1)"}});
  listener({detail: {url: "http://[bad"}});
  listener({detail: {url: ""}});
  listener({detail: null});

  assert.deepEqual(plain(env.opened), [["https://example.test/a", "_blank", "noopener,noreferrer"]]);
});

test("mounting loads the sandbox proxy into the frame container", () => {
  const env = browser();
  const {container} = mount(env);

  assert.deepEqual(container.children, [env.frame]);
  assert.equal(env.frame.src, "/a2ui_phoenix/a2ui_mcp_sandbox.html");
  assert.equal(env.frame.title, "Pong");
});

test("the app's resource goes to the proxy once it is ready, again when it changes", () => {
  const env = browser();
  const {hook, el} = mount(env);

  hook.updated();
  assert.deepEqual(posted(env), []);

  fromApp(env, note("ui/notifications/sandbox-proxy-ready"));
  assert.equal(env.frameWindow.posted[0].origin, ORIGIN);
  assert.deepEqual(posted(env), [
    note("ui/notifications/sandbox-resource-ready", {
      html: "<p>Pong</p>",
      sandbox: "allow-scripts allow-forms allow-modals",
      csp: {connectDomains: ["https://api.test"]},
      permissions: {camera: true},
    }),
  ]);

  hook.updated();
  assert.deepEqual(posted(env), []);

  el.dataset.html = "<p>Pong 2</p>";
  el.dataset.title = "";
  hook.updated();
  assert.equal(posted(env)[0].params.html, "<p>Pong 2</p>");
  assert.equal(env.frame.title, "MCP App");

  delete el.dataset.html;
  hook.updated();
  assert.deepEqual(posted(env), []);
});

test("the handshake, then the bound state", () => {
  const env = browser();
  const {hook, el} = mount(env);

  fromApp(env, request("ui/initialize", {protocolVersion: "2026-01-26"}, 3));
  const [response] = posted(env);
  assert.equal(response.id, 3);
  assert.equal(response.result.protocolVersion, "2026-01-26");
  assert.equal(response.result.hostInfo.name, "a2ui_phoenix");
  assert.deepEqual(response.result.hostContext.containerDimensions, {width: 300, height: 200});
  assert.equal(response.result.hostContext.theme, "dark");

  fromApp(env, note("ui/notifications/initialized"));
  assert.deepEqual(posted(env), [
    note("ui/notifications/data-model-update", {key: "score", value: {a: 1, b: 2}}),
    note("ui/notifications/tool-input", {arguments: {level: 1}}),
  ]);

  el.dataset.state = JSON.stringify({
    score: {a: 1, b: 3},
    toolInput: {level: 1},
    toolResult: {done: true},
  });
  hook.updated();
  assert.deepEqual(posted(env), [
    note("ui/notifications/data-model-update", {key: "score", subpath: "/b", value: 3}),
    note("ui/notifications/tool-result", {
      content: [{type: "text", text: '{"done":true}'}],
      structuredContent: {done: true},
    }),
  ]);
});

test("the app's own writes go to the server and are not echoed back", () => {
  const env = browser();
  const {hook, el, pushed} = mount(env);
  fromApp(env, note("ui/notifications/initialized"));
  posted(env);

  const change = {key: "score", subpath: "/a", value: 9};
  fromApp(env, note("ui/notifications/data-model-change", change));
  fromApp(env, note("ui/notifications/data-model-change", {key: "whole", value: [1]}));
  fromApp(env, note("ui/notifications/data-model-change", {key: 1, value: 2}));
  fromApp(env, note("ui/notifications/data-model-change", {key: "x", value: {constructor: 1}}));

  assert.deepEqual(
    pushed.map((push) => plain(push.payload)),
    [
      {ref: "7", method: "ui/notifications/data-model-change", params: change, id: null},
      {ref: "7", method: "ui/notifications/data-model-change", params: {key: "whole", value: [1]}, id: null},
    ],
  );
  assert.equal(pushed[0].target, el);
  assert.equal(pushed[0].event, "a2ui:mcp_app");

  el.dataset.state = JSON.stringify({score: {a: 9, b: 2}, whole: [1], toolInput: {level: 1}});
  hook.updated();
  assert.deepEqual(posted(env), []);
});

test("requests the server answers are forwarded, and its replies relayed", () => {
  const env = browser();
  const {pushed, handlers} = mount(env);

  fromApp(env, request("tools/call", {name: "move", arguments: {to: 3}}, 5));
  assert.deepEqual(plain(pushed[0].payload), {
    ref: "7",
    method: "tools/call",
    params: {name: "move", arguments: {to: 3}},
    id: 5,
  });

  handlers["a2ui:mcp_app:reply"]({surface_id: "main", ref: 7, id: 5, result: {content: []}});
  handlers["a2ui:mcp_app:reply"]({surface_id: "main", ref: 8, id: 6, result: {}});
  handlers["a2ui:mcp_app:reply"]({surface_id: "other", ref: 7, id: 6, result: {}});
  handlers["a2ui:mcp_app:reply"]({surface_id: "main", ref: 7, id: 9, error: {code: -32602, message: "no"}});

  assert.deepEqual(posted(env), [
    {jsonrpc: "2.0", id: 5, result: {content: []}},
    {jsonrpc: "2.0", id: 9, error: {code: -32602, message: "no"}},
  ]);
});

test("unsafe payloads are refused before they leave the browser", () => {
  const env = browser();
  const {pushed} = mount(env);
  let deep = 1;
  for (let i = 0; i < 12; i++) deep = [deep];

  fromApp(env, request("ui/requests/function-call", JSON.parse('{"call":"f","args":{"__proto__":{}}}'), 1));
  fromApp(env, request("ui/message", {content: deep}, 2));
  fromApp(env, request("tools/call", {name: "t", arguments: {blob: "x".repeat(70000)}}, 3));

  assert.deepEqual(pushed, []);
  assert.deepEqual(
    posted(env).map((message) => [message.id, message.error.code, message.error.message]),
    [
      [1, -32602, "Security validation error: forbidden key '__proto__'"],
      [2, -32602, "Security validation error: payload nested deeper than 10 levels"],
      [3, -32602, "Security validation error: payload larger than 65536 bytes"],
    ],
  );
});

test("links, display mode, logging and unknown methods are answered in the browser", () => {
  const env = browser();
  mount(env);

  fromApp(env, request("ui/open-link", {url: "https://docs.test"}, 1));
  fromApp(env, request("ui/open-link", {url: "javascript:alert(1)"}, 2));
  fromApp(env, request("ui/request-display-mode", {mode: "fullscreen"}, 3));
  fromApp(env, request("nope/nope", {}, 4));
  fromApp(env, note("nope/notification"));
  fromApp(env, note("notifications/message", {level: "info", data: "hi"}));

  assert.deepEqual(plain(env.opened), [["https://docs.test/", "_blank", "noopener,noreferrer"]]);
  assert.deepEqual(plain(env.logged), [["[MCP App]", "info", "hi"]]);
  assert.deepEqual(posted(env), [
    {jsonrpc: "2.0", id: 1, result: {}},
    {jsonrpc: "2.0", id: 2, error: {code: -32602, message: "Only http and https links can be opened."}},
    {jsonrpc: "2.0", id: 3, result: {mode: "inline"}},
    {jsonrpc: "2.0", id: 4, error: {code: -32601, message: "Method not found: nope/nope"}},
  ]);
});

test("messages from elsewhere, or that are not JSON-RPC, are ignored", () => {
  const env = browser();
  const {pushed} = mount(env);

  fromApp(env, request("tools/call", {name: "t"}), {source: {}});
  fromApp(env, request("tools/call", {name: "t"}), {origin: "https://evil.test"});
  fromApp(env, {method: "tools/call", id: 1});
  fromApp(env, "sandbox-init");
  fromApp(env, {jsonrpc: "2.0", id: 1, result: {}});

  assert.deepEqual(pushed, []);
  assert.deepEqual(posted(env), []);
});

test("size changes are clamped, throttled and gated", () => {
  const env = browser();
  const {el} = mount(env);

  fromApp(env, note("ui/notifications/size-changed", {height: 50, width: 9000}));
  fromApp(env, note("ui/notifications/size-changed", {height: 40}));
  assert.equal(env.timers.length, 1);
  env.timers.shift()();
  assert.deepEqual(plain(el.style), {height: "100px"});

  fromApp(env, note("ui/notifications/size-changed", {height: 103, width: 640}));
  env.timers.shift()();
  assert.deepEqual(plain(el.style), {height: "100px", width: "640px"});
});

test("the host context follows the container once the app is initialized", () => {
  const env = browser();
  const {hook} = mount(env);

  hook.hostContextChanged();
  assert.deepEqual(posted(env), []);

  fromApp(env, note("ui/notifications/initialized"));
  posted(env);
  hook.hostContextChanged();
  assert.deepEqual(posted(env), [
    note("ui/notifications/host-context-changed", {
      theme: "dark",
      containerDimensions: {width: 300, height: 200},
    }),
  ]);
});

test("destroying the hook stops listening", () => {
  const env = browser();
  const {hook} = mount(env);
  hook.destroyed();
  assert.equal(env.listeners.message.length, 0);
});

test("helpers", () => {
  const env = browser();
  const {stableStringify, payloadProblem, nextSize, toolResult, stateNotifications} =
    env.window.A2UIPhoenix.mcpApp;

  assert.equal(stableStringify({b: [1, {d: 1, c: 2}], a: undefined}), '{"a":null,"b":[1,{"c":2,"d":1}]}');
  assert.equal(payloadProblem({a: [1, {b: "c"}]}), null);
  assert.equal(payloadProblem({prototype: 1}), "forbidden key 'prototype'");
  assert.deepEqual(plain(nextSize({width: 100, height: "x"}, {})), {width: 200});
  assert.deepEqual(plain(nextSize({width: 202}, {width: 200})), {});

  const result = {content: [{type: "text", text: "ok"}]};
  assert.equal(toolResult(result), result);
  assert.deepEqual(plain(toolResult(3)), {content: [{type: "text", text: "3"}], structuredContent: 3});

  assert.deepEqual(plain(stateNotifications({a: {x: 1}}, {a: {x: 1, y: 2}})), [
    {jsonrpc: "2.0", method: "ui/notifications/data-model-update", params: {key: "a", value: {x: 1}}},
  ]);
  assert.deepEqual(plain(stateNotifications({"a/b": {"c~d": 1}}, {"a/b": {"c~d": 0}})), [
    {
      jsonrpc: "2.0",
      method: "ui/notifications/data-model-update",
      params: {key: "a/b", subpath: "/c~0d", value: 1},
    },
  ]);
  assert.deepEqual(plain(stateNotifications({n: 1, toolInput: null, modelContext: 1}, {n: 1})), []);
});
