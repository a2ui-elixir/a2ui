// Browser support for A2UIPhoenix:
//
//   * opens the URL an A2UI `openUrl` action asks for: A2UIPhoenix.Live
//     pushes it as the "a2ui:open_url" event, which LiveView dispatches on
//     window with a "phx:" prefix;
//   * keeps a Slider's filled track and value in step with its thumb while
//     it moves, before the server renders them;
//   * the `A2UIMcpApp` hook, the host side of the MCP Apps bridge of the
//     MCP catalog's `McpApp` component (A2UIPhoenix.Components.MCP).
//
// Register the hooks with the LiveSocket:
//
//   new LiveSocket("/live", Socket, {hooks: {...window.A2UIPhoenix.hooks}})
(function () {
  "use strict";

  const A2UIPhoenix = (window.A2UIPhoenix = window.A2UIPhoenix || {});

  // -- openUrl ------------------------------------------------------------------

  // The basic catalog's openUrl already allows only these schemes; they are
  // checked again here before anything opens.
  const URL_SCHEMES = ["http:", "https:", "mailto:", "tel:"];

  function openUrl(raw, schemes) {
    if (typeof raw !== "string" || raw === "") return false;

    let url;
    try {
      url = new URL(raw, window.location.href);
    } catch {
      return false;
    }

    if (!schemes.includes(url.protocol)) return false;
    window.open(url.toString(), "_blank", "noopener,noreferrer");
    return true;
  }

  window.addEventListener("phx:a2ui:open_url", (event) => {
    openUrl(event.detail && event.detail.url, URL_SCHEMES);
  });

  // -- Slider -------------------------------------------------------------------

  window.addEventListener("input", (event) => {
    const input = event.target;
    if (!input || !input.classList || !input.classList.contains("a2ui-slider-input")) return;

    const slider = input.closest(".a2ui-slider");
    if (!slider) return;

    const min = Number(input.min || 0);
    const max = Number(input.max || 100);
    const value = Math.min(Math.max(Number(input.value), min), max);
    const fill = max > min ? ((value - min) / (max - min)) * 100 : 0;
    slider.style.setProperty("--a2ui-slider-fill", Math.round(fill * 100) / 100 + "%");

    const output = slider.querySelector(".a2ui-slider-value");
    if (output) output.textContent = input.value;
  });

  // -- MCP Apps -----------------------------------------------------------------

  const PROTOCOL_VERSION = "2026-01-26";
  const SANDBOX_FLAGS = "allow-scripts allow-forms allow-modals";
  const LINK_SCHEMES = ["http:", "https:"];
  // Requests the server answers (A2UIPhoenix.Session.mcp_app_request/5).
  const FORWARDED = [
    "tools/call",
    "ui/requests/function-call",
    "ui/update-model-context",
    "ui/message",
  ];
  const MAX_DEPTH = 10;
  const MAX_BYTES = 65536;
  const FORBIDDEN_KEYS = ["__proto__", "constructor", "prototype"];

  function isObject(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value);
  }

  // JSON with object keys sorted, for comparing values.
  function stableStringify(value) {
    if (Array.isArray(value)) return "[" + value.map(stableStringify).join(",") + "]";

    if (isObject(value)) {
      const fields = Object.keys(value)
        .sort()
        .map((key) => JSON.stringify(key) + ":" + stableStringify(value[key]));
      return "{" + fields.join(",") + "}";
    }

    return JSON.stringify(value === undefined ? null : value);
  }

  // Why a payload from the app is unsafe, or null: a prototype key at any
  // depth, nesting deeper than 10 levels, more than 64 KiB of JSON.
  function payloadProblem(payload) {
    const visit = (value, depth) => {
      if (depth > MAX_DEPTH) return "payload nested deeper than " + MAX_DEPTH + " levels";
      const entries = Array.isArray(value)
        ? value.map((item) => [null, item])
        : isObject(value)
          ? Object.keys(value).map((key) => [key, value[key]])
          : [];

      for (const [key, item] of entries) {
        if (FORBIDDEN_KEYS.includes(key)) return "forbidden key '" + key + "'";
        const problem = visit(item, depth + 1);
        if (problem) return problem;
      }

      return null;
    };

    const problem = visit(payload, 0);
    if (problem) return problem;

    const json = JSON.stringify(payload === undefined ? null : payload);
    return new TextEncoder().encode(json).length > MAX_BYTES
      ? "payload larger than " + MAX_BYTES + " bytes"
      : null;
  }

  // The frame size to apply for a size-changed request: clamped to
  // 200-3000 px wide and 100-2000 px high; changes under 5 px are dropped.
  function nextSize(requested, last) {
    const pick = (value, min, max, previous) => {
      if (typeof value !== "number" || !isFinite(value)) return undefined;
      const clamped = Math.max(min, Math.min(value, max));
      return previous === undefined || Math.abs(clamped - previous) >= 5 ? clamped : undefined;
    };

    return {
      width: pick(requested.width, 200, 3000, last.width),
      height: pick(requested.height, 100, 2000, last.height),
    };
  }

  // A tool result bound to `toolResult`: a CallToolResult as it is, any
  // other value as its structured content.
  function toolResult(value) {
    if (isObject(value) && Array.isArray(value.content)) return value;
    return {content: [{type: "text", text: JSON.stringify(value)}], structuredContent: value};
  }

  function notification(method, params) {
    return {jsonrpc: "2.0", method: method, params: params};
  }

  function pointerToken(key) {
    return key.replace(/~/g, "~0").replace(/\//g, "~1");
  }

  // The notifications that bring the app up to date with `state`, given the
  // values it holds (`sent`): tool input and result for the reserved keys;
  // for an object the app already has, one data-model-update per changed
  // field; otherwise the whole value. `modelContext` flows only from the
  // app; a reserved key without a value yet is not sent.
  function stateNotifications(state, sent) {
    const notifications = [];

    for (const key of Object.keys(state)) {
      const value = state[key];
      const known = Object.prototype.hasOwnProperty.call(sent, key);
      if (key === "modelContext") continue;
      if (known && stableStringify(sent[key]) === stableStringify(value)) continue;

      if (key === "toolInput" || key === "toolResult") {
        if (value === null || value === undefined) continue;
        notifications.push(
          key === "toolInput"
            ? notification("ui/notifications/tool-input", {arguments: value})
            : notification("ui/notifications/tool-result", toolResult(value)),
        );
      } else if (known && isObject(value) && isObject(sent[key]) && keepsFields(sent[key], value)) {
        for (const field of Object.keys(value)) {
          if (stableStringify(sent[key][field]) === stableStringify(value[field])) continue;
          notifications.push(
            notification("ui/notifications/data-model-update", {
              key: key,
              subpath: "/" + pointerToken(field),
              value: value[field],
            }),
          );
        }
      } else {
        notifications.push(notification("ui/notifications/data-model-update", {key: key, value: value}));
      }
    }

    return notifications;
  }

  function keepsFields(before, after) {
    return Object.keys(before).every((field) => Object.prototype.hasOwnProperty.call(after, field));
  }

  function parse(json, fallback) {
    try {
      return json ? JSON.parse(json) : fallback;
    } catch {
      return fallback;
    }
  }

  const McpApp = {
    mounted() {
      this.sent = {};
      this.size = {};
      this.initialized = false;
      this.proxyReady = false;
      this.resourceKey = null;

      this.origin = new URL(this.el.dataset.sandbox, window.location.href).origin;
      this.frame = document.createElement("iframe");
      this.frame.title = this.el.dataset.title || "MCP App";
      this.frame.src = this.el.dataset.sandbox;
      this.el.querySelector("[data-a2ui-mcp-frame]").appendChild(this.frame);

      this.onMessage = (event) => this.receive(event);
      window.addEventListener("message", this.onMessage);
      this.handleEvent("a2ui:mcp_app:reply", (reply) => this.reply(reply));

      if (typeof ResizeObserver === "function") {
        this.observer = new ResizeObserver(() => this.hostContextChanged());
        this.observer.observe(this.el);
      }

      // The theme follows the page: a new color-scheme on its root (a
      // theme switch), or the system's.
      this.onThemeChange = () => this.hostContextChanged();
      this.media = window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)");
      if (this.media && this.media.addEventListener) this.media.addEventListener("change", this.onThemeChange);

      if (typeof MutationObserver === "function" && document.documentElement) {
        this.themeObserver = new MutationObserver(this.onThemeChange);
        this.themeObserver.observe(document.documentElement, {attributes: true});
      }
    },

    updated() {
      this.frame.title = this.el.dataset.title || "MCP App";
      this.sendResource();
      if (this.initialized) this.sendState();
    },

    destroyed() {
      window.removeEventListener("message", this.onMessage);
      if (this.observer) this.observer.disconnect();
      if (this.themeObserver) this.themeObserver.disconnect();
      if (this.media && this.media.removeEventListener) this.media.removeEventListener("change", this.onThemeChange);
      clearTimeout(this.resizeTimer);
    },

    post(message) {
      if (this.frame.contentWindow) this.frame.contentWindow.postMessage(message, this.origin);
    },

    respond(id, result) {
      this.post({jsonrpc: "2.0", id: id, result: result});
    },

    respondError(id, code, message) {
      this.post({jsonrpc: "2.0", id: id, error: {code: code, message: message}});
    },

    receive(event) {
      if (event.source !== this.frame.contentWindow || event.origin !== this.origin) return;

      const message = event.data;
      if (!isObject(message) || message.jsonrpc !== "2.0" || typeof message.method !== "string") return;

      const params = isObject(message.params) ? message.params : {};
      const id = message.id === undefined ? null : message.id;

      switch (message.method) {
        case "ui/notifications/sandbox-proxy-ready":
          this.proxyReady = true;
          this.resourceKey = null;
          this.sendResource();
          return;
        case "ui/initialize":
          return this.respond(id, this.initializeResult());
        case "ui/notifications/initialized":
          this.initialized = true;
          this.sent = {};
          return this.sendState();
        case "ui/notifications/size-changed":
          return this.resize(params);
        case "notifications/message":
          return console.log("[MCP App]", params.level, params.data);
        case "ui/open-link":
          return this.openLink(id, params);
        case "ui/request-display-mode":
          return this.respond(id, {mode: "inline"});
        case "ui/notifications/data-model-change":
          return this.dataModelChange(params);
        default:
          if (id === null) return;
          if (FORWARDED.includes(message.method)) return this.forward(message.method, params, id);
          return this.respondError(id, -32601, "Method not found: " + message.method);
      }
    },

    forward(method, params, id) {
      const problem = payloadProblem(params);
      if (problem) return this.respondError(id, -32602, "Security validation error: " + problem);
      this.pushEventTo(this.el, "a2ui:mcp_app", {ref: this.el.dataset.ref, method: method, params: params, id: id});
    },

    // The app's own write is what it already holds: noting it here keeps
    // the host from echoing it back.
    dataModelChange(params) {
      if (typeof params.key !== "string" || payloadProblem(params.value)) return;

      const field = typeof params.subpath === "string" ? params.subpath.replace(/^\//, "") : "";
      if (field === "") {
        this.sent[params.key] = params.value;
      } else if (!field.includes("/") && isObject(this.sent[params.key])) {
        this.sent[params.key] = Object.assign({}, this.sent[params.key], {
          [field.replace(/~1/g, "/").replace(/~0/g, "~")]: params.value,
        });
      }

      this.pushEventTo(this.el, "a2ui:mcp_app", {
        ref: this.el.dataset.ref,
        method: "ui/notifications/data-model-change",
        params: params,
        id: null,
      });
    },

    reply(reply) {
      if (reply.surface_id !== this.el.dataset.surface || String(reply.ref) !== this.el.dataset.ref) return;
      if (reply.error) return this.respondError(reply.id, reply.error.code, reply.error.message);
      this.respond(reply.id, reply.result);
    },

    sendResource() {
      const html = this.el.dataset.html;
      if (!this.proxyReady || typeof html !== "string") return;

      const key = JSON.stringify([html, this.el.dataset.csp, this.el.dataset.permissions]);
      if (key === this.resourceKey) return;

      this.resourceKey = key;
      this.initialized = false;
      this.sent = {};
      this.post(
        notification("ui/notifications/sandbox-resource-ready", {
          html: html,
          sandbox: SANDBOX_FLAGS,
          csp: parse(this.el.dataset.csp, {}),
          permissions: parse(this.el.dataset.permissions, {}),
        }),
      );
    },

    sendState() {
      const state = parse(this.el.dataset.state, {});
      for (const message of stateNotifications(state, this.sent)) this.post(message);
      for (const key of Object.keys(state)) {
        const reserved = key === "toolInput" || key === "toolResult";
        if (!reserved || (state[key] !== null && state[key] !== undefined)) this.sent[key] = state[key];
      }
    },

    // The theme the component is drawn in: its color-scheme (light, dark,
    // or both, which follows the system), as the stylesheet's colors do.
    theme() {
      const prefersDark = Boolean(window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches);
      if (typeof window.getComputedStyle !== "function") return prefersDark ? "dark" : "light";

      const schemes = String(window.getComputedStyle(this.el).colorScheme || "normal").split(/\s+/);
      const light = schemes.includes("light");
      const dark = schemes.includes("dark");
      if (light && dark) return prefersDark ? "dark" : "light";
      return dark ? "dark" : "light";
    },

    hostContext() {
      const rect = this.el.getBoundingClientRect();

      return {
        theme: this.theme(),
        displayMode: "inline",
        availableDisplayModes: ["inline"],
        containerDimensions: {width: rect.width, height: rect.height},
      };
    },

    initializeResult() {
      return {
        protocolVersion: PROTOCOL_VERSION,
        hostInfo: {name: "a2ui_phoenix", version: "0.1.0"},
        hostCapabilities: {openLinks: {}, logging: {}, serverTools: {}},
        hostContext: this.hostContext(),
      };
    },

    hostContextChanged() {
      if (!this.initialized) return;
      const context = this.hostContext();
      this.post(
        notification("ui/notifications/host-context-changed", {
          theme: context.theme,
          containerDimensions: context.containerDimensions,
        }),
      );
    },

    openLink(id, params) {
      if (openUrl(params.url, LINK_SCHEMES)) return this.respond(id, {});
      this.respondError(id, -32602, "Only http and https links can be opened.");
    },

    // At most one resize per 100 ms, to the latest size asked for.
    resize(params) {
      this.requestedSize = params;
      if (this.resizeTimer) return;

      this.resizeTimer = setTimeout(() => {
        this.resizeTimer = null;
        const size = nextSize(this.requestedSize, this.size);

        if (size.width !== undefined) {
          this.el.style.width = size.width + "px";
          this.size.width = size.width;
        }

        if (size.height !== undefined) {
          this.el.style.height = size.height + "px";
          this.size.height = size.height;
        }
      }, 100);
    },
  };

  A2UIPhoenix.mcpApp = {
    stableStringify: stableStringify,
    payloadProblem: payloadProblem,
    nextSize: nextSize,
    toolResult: toolResult,
    stateNotifications: stateNotifications,
  };

  A2UIPhoenix.hooks = Object.assign(A2UIPhoenix.hooks || {}, {A2UIMcpApp: McpApp});
})();
