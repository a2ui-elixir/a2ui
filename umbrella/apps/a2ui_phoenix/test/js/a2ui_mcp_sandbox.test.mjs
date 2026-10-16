// Tests for priv/static/a2ui_mcp_sandbox.html: the sandbox proxy's script,
// run in a VM context with a stand-in frame.
import {test} from "node:test";
import assert from "node:assert/strict";
import {readFileSync} from "node:fs";
import vm from "node:vm";

const html = readFileSync(new URL("../../priv/static/a2ui_mcp_sandbox.html", import.meta.url), "utf8");
const script = html.slice(html.indexOf("<script>") + "<script>".length, html.indexOf("</script>"));
const PARENT = "https://host.test";

// Values made inside the VM have its prototypes; compare them as JSON.
const plain = (value) => JSON.parse(JSON.stringify(value));

function proxy({framed = true, referrer = PARENT + "/page"} = {}) {
  const listeners = {};
  const parentPosted = [];
  const parent = {postMessage: (message, origin) => parentPosted.push({message, origin})};
  const innerWindow = {posted: [], postMessage(message, origin) { this.posted.push({message, origin}); }};
  const inner = {
    attributes: {},
    setAttribute(name, value) { this.attributes[name] = value; },
    contentWindow: innerWindow,
    srcdoc: "",
    onload: null,
  };
  const appended = [];
  const top = {};

  const window = {
    self: framed ? {} : top,
    top,
    parent,
    addEventListener(type, listener) { listeners[type] = listener; },
  };

  const document = {referrer, createElement: () => inner, body: {appendChild: (child) => appended.push(child)}};
  vm.runInContext(script, vm.createContext({window, document, URL}));
  return {window, listeners, parent, parentPosted, inner, innerWindow, appended};
}

test("the proxy announces itself to the page that embeds it", () => {
  const env = proxy();

  assert.deepEqual(env.appended, [env.inner]);
  assert.equal(env.inner.attributes.sandbox, "allow-scripts allow-forms allow-modals");
  assert.match(env.inner.attributes.allow, /^camera 'none'; /);
  assert.deepEqual(plain(env.parentPosted), [
    {message: {jsonrpc: "2.0", method: "ui/notifications/sandbox-proxy-ready", params: {}}, origin: PARENT},
  ]);
});

test("the resource loads into the inner frame under the policy", () => {
  const env = proxy();

  env.listeners.message({
    source: env.parent,
    origin: PARENT,
    data: {
      jsonrpc: "2.0",
      method: "ui/notifications/sandbox-resource-ready",
      params: {
        html: "<!DOCTYPE html><html><head></head><body><script>run()</script></body></html>",
        sandbox: "allow-scripts allow-same-origin allow-top-navigation allow-popups",
        csp: {connectDomains: ["https://api.test", "bad;src"], resourceDomains: ["https://cdn.test"]},
        permissions: {camera: true, clipboardWrite: {}},
      },
    },
  });

  assert.equal(env.inner.attributes.sandbox, "allow-scripts allow-popups");
  assert.equal(
    env.inner.attributes.allow,
    "camera; microphone 'none'; geolocation 'none'; clipboard-read 'none'; clipboard-write;",
  );
  assert.ok(env.inner.srcdoc.startsWith('<!DOCTYPE html><meta http-equiv="Content-Security-Policy" content="'));
  assert.ok(env.inner.srcdoc.includes("connect-src https://api.test;"));
  assert.ok(env.inner.srcdoc.includes("default-src 'self' 'unsafe-inline' 'unsafe-eval' data: blob: https://cdn.test;"));
  assert.ok(env.inner.srcdoc.includes("frame-src 'none'; base-uri 'none'; form-action 'none';"));
  assert.ok(!env.inner.srcdoc.includes("bad;src"));
  assert.ok(env.inner.srcdoc.endsWith("<html><head></head><body><script>run()</script></body></html>"));

  env.inner.onload();
  assert.deepEqual(plain(env.innerWindow.posted), [{message: {type: "sandbox-init"}, origin: "*"}]);
});

test("messages are relayed between the page and the app", () => {
  const env = proxy();
  const request = {jsonrpc: "2.0", id: 1, method: "ui/initialize", params: {}};
  const response = {jsonrpc: "2.0", id: 1, result: {}};

  env.listeners.message({source: env.innerWindow, origin: "null", data: request});
  env.listeners.message({source: env.parent, origin: PARENT, data: response});
  env.listeners.message({source: env.parent, origin: "https://evil.test", data: response});
  env.listeners.message({source: {}, origin: PARENT, data: response});

  assert.deepEqual(plain(env.parentPosted.slice(1)), [{message: request, origin: PARENT}]);
  assert.deepEqual(plain(env.innerWindow.posted), [{message: response, origin: "*"}]);
});

test("a resource without HTML loads an empty document under the policy", () => {
  const env = proxy();
  env.listeners.message({
    source: env.parent,
    origin: PARENT,
    data: {method: "ui/notifications/sandbox-resource-ready", params: null},
  });

  assert.equal(env.inner.attributes.sandbox, "allow-scripts allow-forms allow-modals");
  assert.match(env.inner.srcdoc, /^<meta http-equiv="Content-Security-Policy"/);
});

test("outside a frame, or without a referrer, the proxy does nothing", () => {
  for (const env of [proxy({framed: false}), proxy({referrer: ""}), proxy({referrer: "not a url"})]) {
    assert.equal(env.appended.length, 0);
    assert.equal(env.parentPosted.length, 0);
    assert.equal(typeof env.window.A2UIMcpSandbox.prepare, "function");
  }
});

test("helpers", () => {
  const {contentSecurityPolicy, prepare, sandboxFlags, allowAttribute} = proxy().window.A2UIMcpSandbox;

  assert.equal(
    contentSecurityPolicy(null),
    "default-src 'self' 'unsafe-inline' 'unsafe-eval' data: blob:; connect-src 'none'; " +
      "frame-src 'none'; base-uri 'none'; form-action 'none';",
  );
  assert.ok(contentSecurityPolicy({frameDomains: ["https://f.test"], baseUriDomains: ["https://b.test"]})
    .includes("frame-src https://f.test; base-uri https://b.test;"));
  assert.ok(prepare("<p>x</p>", {}).endsWith("<p>x</p>"));
  assert.equal(sandboxFlags(undefined), "allow-scripts allow-forms allow-modals");
  assert.equal(sandboxFlags("  allow-scripts   allow-top-navigation-by-user-activation "), "allow-scripts");
  assert.equal(allowAttribute("camera"), allowAttribute({}));
});
