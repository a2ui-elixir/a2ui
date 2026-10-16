// A2UI for Elixir: the landing page's behaviour. Everything here is an
// enhancement; the page reads and works without it.
(function () {
  "use strict";

  var root = document.documentElement;
  var reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  var prefersLight = window.matchMedia("(prefers-color-scheme: light)");

  function each(selector, fn, scope) {
    Array.prototype.forEach.call((scope || document).querySelectorAll(selector), fn);
  }

  function remember(key, value) {
    try {
      localStorage.setItem(key, value);
    } catch (error) {
      // Storage can be unavailable (private windows, blocked site data).
    }
  }

  function flash(element) {
    element.classList.remove("flash");
    void element.offsetWidth;
    element.classList.add("flash");
  }

  // Theme: the system's unless the visitor picked one.
  function theme() {
    var picked = root.getAttribute("data-theme");
    if (picked === "light" || picked === "dark") return picked;
    return prefersLight.matches ? "light" : "dark";
  }

  function syncThemeToggle() {
    each("[data-theme-toggle]", function (button) {
      button.setAttribute("aria-pressed", String(theme() === "dark"));
    });
  }

  function initTheme() {
    syncThemeToggle();
    each("[data-theme-toggle]", function (button) {
      button.addEventListener("click", function () {
        var next = theme() === "dark" ? "light" : "dark";
        root.setAttribute("data-theme", next);
        remember("theme", next);
        syncThemeToggle();
      });
    });
    if (prefersLight.addEventListener) prefersLight.addEventListener("change", syncThemeToggle);
  }

  // Header: a background once the page scrolls, and the menu on small screens.
  function initHeader() {
    var header = document.querySelector("[data-header]");
    var toggle = document.querySelector("[data-menu-toggle]");
    if (!header) return;

    var ticking = false;
    function update() {
      header.classList.toggle("is-scrolled", window.scrollY > 8);
      ticking = false;
    }
    window.addEventListener(
      "scroll",
      function () {
        if (!ticking) {
          ticking = true;
          window.requestAnimationFrame(update);
        }
      },
      { passive: true }
    );
    update();

    if (!toggle) return;

    function setOpen(open) {
      header.classList.toggle("nav-open", open);
      toggle.setAttribute("aria-expanded", String(open));
    }

    toggle.addEventListener("click", function () {
      setOpen(!header.classList.contains("nav-open"));
    });
    each(".site-nav a", function (link) {
      link.addEventListener("click", function () {
        setOpen(false);
      });
    });
    document.addEventListener("keydown", function (event) {
      if (event.key === "Escape" && header.classList.contains("nav-open")) {
        setOpen(false);
        toggle.focus();
      }
    });
    document.addEventListener("click", function (event) {
      if (header.classList.contains("nav-open") && !header.contains(event.target)) setOpen(false);
    });
    window.addEventListener("resize", function () {
      if (window.innerWidth > 1060) setOpen(false);
    });
  }

  // The navigation link of the section in view.
  function initActiveSection() {
    if (!("IntersectionObserver" in window)) return;
    var links = {};
    each("[data-nav-link]", function (link) {
      links[link.getAttribute("href").slice(1)] = link;
    });
    var observer = new IntersectionObserver(
      function (entries) {
        entries.forEach(function (entry) {
          var link = links[entry.target.id];
          if (link) link.classList.toggle("is-active", entry.isIntersecting);
        });
      },
      { rootMargin: "-45% 0px -50% 0px" }
    );
    Object.keys(links).forEach(function (id) {
      var section = document.getElementById(id);
      if (section) observer.observe(section);
    });
  }

  // Tabs, with the keyboard behaviour of the ARIA tabs pattern.
  function initTabs() {
    each("[data-tabs]", function (container) {
      var tabs = Array.prototype.slice.call(container.querySelectorAll('[role="tab"]'));

      function select(tab, focus) {
        tabs.forEach(function (other) {
          var selected = other === tab;
          other.setAttribute("aria-selected", String(selected));
          other.tabIndex = selected ? 0 : -1;
          var panel = document.getElementById(other.getAttribute("aria-controls"));
          if (panel) panel.hidden = !selected;
        });
        if (focus) tab.focus();
      }

      tabs.forEach(function (tab, index) {
        tab.addEventListener("click", function () {
          select(tab, false);
        });
        tab.addEventListener("keydown", function (event) {
          var target = null;
          if (event.key === "ArrowRight") target = tabs[(index + 1) % tabs.length];
          if (event.key === "ArrowLeft") target = tabs[(index - 1 + tabs.length) % tabs.length];
          if (event.key === "Home") target = tabs[0];
          if (event.key === "End") target = tabs[tabs.length - 1];
          if (target) {
            event.preventDefault();
            select(target, true);
          }
        });
      });

      var current = tabs.filter(function (tab) {
        return tab.getAttribute("aria-selected") === "true";
      })[0];
      if (current) select(current, false);
      container.classList.add("tabs-ready");
    });
  }

  // Copy buttons.
  // The Clipboard API where the page may use it, else the older command.
  function copyText(text) {
    if (navigator.clipboard && window.isSecureContext) {
      return navigator.clipboard.writeText(text).catch(function () {
        return copyWithCommand(text);
      });
    }
    return copyWithCommand(text);
  }

  function copyWithCommand(text) {
    return new Promise(function (resolve, reject) {
      var area = document.createElement("textarea");
      area.value = text;
      area.setAttribute("readonly", "");
      area.style.position = "fixed";
      area.style.opacity = "0";
      document.body.appendChild(area);
      area.select();
      var copied = false;
      try {
        copied = document.execCommand("copy");
      } catch (error) {
        copied = false;
      }
      document.body.removeChild(area);
      if (copied) resolve();
      else reject(new Error("copy failed"));
    });
  }

  // The code a copy button copies: its panel's, or the open tab's in an editor.
  function codeFor(button) {
    var tabs = button.closest("[data-tabs]");
    if (tabs) return tabs.querySelector(".tab-panel:not([hidden]) pre code");
    return button.closest(".code-panel").querySelector("pre code");
  }

  function selectContents(element) {
    var range = document.createRange();
    range.selectNodeContents(element);
    var selection = window.getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
  }

  function initCopy() {
    each("[data-copy]", function (button) {
      var label = button.querySelector("[data-copy-label]");
      var timer = null;
      button.addEventListener("click", function () {
        var code = codeFor(button);
        copyText(code.textContent).then(
          function () {
            show("Copied");
          },
          function () {
            show("Press Ctrl+C");
            selectContents(code);
          }
        );
      });
      function show(text) {
        button.classList.add("is-copied");
        if (label) label.textContent = text;
        window.clearTimeout(timer);
        timer = window.setTimeout(function () {
          button.classList.remove("is-copied");
          if (label) label.textContent = "Copy";
        }, 1600);
      }
    });

    each("[data-copy-text]", function (button) {
      var timer = null;
      button.addEventListener("click", function () {
        copyText(button.getAttribute("data-copy-text")).then(
          function () {
            button.classList.add("is-copied");
            window.clearTimeout(timer);
            timer = window.setTimeout(function () {
              button.classList.remove("is-copied");
            }, 1600);
          },
          function () {
            var code = button.parentElement.querySelector("code");
            if (code) selectContents(code);
          }
        );
      });
    });
  }

  // Elements fade in as they scroll into view. Those already in view stay as
  // they are, so nothing on screen flickers.
  function initReveal() {
    if (!("IntersectionObserver" in window) || reducedMotion.matches) return;
    var items = Array.prototype.slice.call(document.querySelectorAll("[data-reveal]"));
    var height = window.innerHeight;

    items.forEach(function (item) {
      var box = item.getBoundingClientRect();
      if (box.top < height && box.bottom > 0) {
        item.classList.add("is-visible");
        return;
      }
      var siblings = Array.prototype.filter.call(item.parentElement.children, function (child) {
        return child.hasAttribute("data-reveal");
      });
      var index = siblings.indexOf(item) % 3;
      if (index > 0) item.style.transitionDelay = index * 90 + "ms";
    });

    root.classList.add("reveal-ready");

    var observer = new IntersectionObserver(
      function (entries) {
        entries.forEach(function (entry) {
          if (!entry.isIntersecting) return;
          var item = entry.target;
          item.classList.add("is-visible");
          observer.unobserve(item);
          window.setTimeout(function () {
            item.style.transitionDelay = "";
          }, 1200);
        });
      },
      { rootMargin: "0px 0px -6% 0px", threshold: 0.06 }
    );
    items.forEach(function (item) {
      if (!item.classList.contains("is-visible")) observer.observe(item);
    });
  }

  // A soft light that follows the pointer over cards.
  function initSpotlight() {
    if (!window.matchMedia("(hover: hover)").matches) return;
    document.addEventListener(
      "pointermove",
      function (event) {
        var card = event.target.closest && event.target.closest(".cell");
        if (!card) return;
        var box = card.getBoundingClientRect();
        card.style.setProperty("--mx", event.clientX - box.left + "px");
        card.style.setProperty("--my", event.clientY - box.top + "px");
      },
      { passive: true }
    );
  }

  // The hero: replay the message, keep the data model in step with the
  // inputs, and show the action the button sends.
  function initDemo() {
    var demo = document.querySelector("[data-demo]");
    if (!demo) return;

    var replay = demo.querySelector("[data-demo-replay]");
    var sent = demo.querySelector("[data-demo-sent]");
    var sentCode = demo.querySelector("[data-demo-sent-code]");
    var button = demo.querySelector("[data-demo-action]");

    function value(path) {
      var input = demo.querySelector('[data-bind="' + path + '"]');
      return input ? input.value : "";
    }

    if (replay) {
      replay.addEventListener("click", function () {
        sent.hidden = true;
        demo.classList.add("is-reset");
        void demo.offsetWidth;
        demo.classList.remove("is-reset");
      });
    }

    each(
      "[data-bind]",
      function (input) {
        input.addEventListener("input", function () {
          var output = demo.querySelector('[data-bound="' + input.getAttribute("data-bind") + '"]');
          if (!output) return;
          output.textContent = JSON.stringify(input.value);
          flash(output);
        });
      },
      demo
    );

    if (button) {
      button.addEventListener("click", function () {
        var timestamp = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
        var context = { name: value("/booking/name"), date: value("/booking/date") };
        sentCode.textContent =
          '{"version": "v1.0", "action": {\n' +
          '  "name": "book", "surfaceId": "booking", "sourceComponentId": "book",\n' +
          '  "timestamp": "' + timestamp + '",\n' +
          '  "context": ' + JSON.stringify(context).replace(/,"/g, ', "').replace(/":/g, '": ') + "}}";
        sent.hidden = false;
        flash(sent.querySelector("pre"));
      });
    }
  }

  // Replays: recorded runs of the examples. A step holds the HTML of the
  // surfaces it changed, the messages that crossed, what was said and what
  // the user does next; the player builds the conversation up to a step
  // (as Site.Replays.view/2 does on the server) and acts out each move.
  function initReplays() {
    var player = document.querySelector("[data-replays]");
    var data = document.getElementById("replay-data");
    if (!player || !data) return;

    var replays;
    try {
      replays = JSON.parse(data.textContent).replays;
    } catch (error) {
      return;
    }

    function part(name) {
      return player.querySelector("[data-replay-" + name + "]");
    }

    var tabs = Array.prototype.slice.call(player.querySelectorAll("[data-replay-tab]"));
    var panel = player.querySelector('[role="tabpanel"]');
    var chat = part("chat");
    var log = part("log");
    var stream = part("stream");
    var streamText = part("stream-text");
    var clock = part("clock");
    var counts = part("counts");
    var caption = part("caption");
    var summary = part("summary");
    var source = part("source");
    var position = part("position");
    var next = part("next");
    var nextLabel = part("next-label");
    var back = part("back");
    var forward = part("forward");
    var restart = part("restart");

    // A streamed replay plays at its recorded pace, a little slowed down.
    var pace = 1.5;
    var current = 0;
    var index = 0;
    var playing = false;
    var moving = null;
    var timers = [];
    var shown = 0;

    function later(fn, ms) {
      timers.push(window.setTimeout(fn, ms));
    }

    function stop() {
      timers.forEach(window.clearTimeout);
      timers = [];
      moving = null;
      playing = false;
    }

    function escapeHTML(text) {
      return String(text).replace(/[&<>"']/g, function (char) {
        return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[char];
      });
    }

    // The JSON rules of SiteWeb.Code.
    var jsonToken =
      /("(?:\\.|[^"\\])*")(\s*:)?|\b(true|false|null)\b|(-?\d+(?:\.\d+)?(?:[eE][+-]?\d+)?)|([A-Za-z_$][\w$-]*)/g;

    function highlight(text) {
      var html = "";
      var last = 0;
      text.replace(jsonToken, function (match, string, colon, keyword, number, word, offset) {
        html += escapeHTML(text.slice(last, offset));
        if (string) {
          html += '<span class="t-' + (colon ? "a" : "s") + '">' + escapeHTML(string) + "</span>";
          html += escapeHTML(colon || "");
        } else if (keyword) {
          html += '<span class="t-k">' + match + "</span>";
        } else if (number) {
          html += '<span class="t-n">' + match + "</span>";
        } else {
          html += escapeHTML(match);
        }
        last = offset + match.length;
        return match;
      });
      return html + escapeHTML(text.slice(last));
    }

    function view(replay, at) {
      var state = { chat: [], surfaces: {}, entries: [], stream: "", chunk: "", caption: "" };

      for (var i = 0; i <= at; i++) {
        var step = replay.steps[i];
        var previous = replay.steps[i - 1];
        var entries = step.entries || [];
        var order = step.order || [];
        var changed = step.surfaces || {};

        if (step.user) {
          state.chat.push({ type: "user", text: step.user });
        } else if (previous && previous.next && previous.next.do === "click") {
          var action = entries.filter(function (entry) {
            return entry.dir === "out" && entry.kind === "action";
          })[0];
          if (action) {
            state.chat.push({ type: "action", label: previous.next.label, name: action.message.action.name });
          }
        }

        if (step.said) state.chat.push({ type: "agent", text: step.said });
        if (step.said_more) {
          for (var j = state.chat.length - 1; j >= 0; j--) {
            if (state.chat[j].type === "agent") {
              state.chat[j].text += step.said_more;
              break;
            }
          }
        }

        var shown = {};
        state.chat.forEach(function (item) {
          if (item.type !== "surface") return;
          if (order.indexOf(item.id) < 0) item.type = "deleted";
          else shown[item.id] = true;
        });
        order.forEach(function (id) {
          if (changed[id] !== undefined && !shown[id]) state.chat.push({ type: "surface", id: id });
        });
        Object.keys(changed).forEach(function (id) {
          state.surfaces[id] = changed[id];
        });
        Object.keys(state.surfaces).forEach(function (id) {
          if (order.indexOf(id) < 0) delete state.surfaces[id];
        });

        entries.forEach(function (entry) {
          state.entries.push({ entry: entry, step: i });
        });
        state.stream += step.chunk || "";
        state.chunk = step.chunk || "";
        if (step.caption) state.caption = step.caption;
      }

      return state;
    }

    function bubble(kind, who, html) {
      return '<div class="chat-item ' + kind + '"><span class="chat-who">' + who + "</span><p>" + html + "</p></div>";
    }

    function chatHTML(state) {
      return state.chat
        .map(function (item) {
          if (item.type === "user") return bubble("chat-user", "you", escapeHTML(item.text));
          if (item.type === "agent") return bubble("chat-agent", "agent", escapeHTML(item.text));
          if (item.type === "action") {
            var label = escapeHTML(item.label) + "<code>action: " + escapeHTML(item.name) + "</code>";
            return bubble("chat-action", "you", label);
          }
          if (item.type === "surface") {
            return (
              '<figure class="chat-item chat-surface" data-surface="' + escapeHTML(item.id) + '">' +
              "<figcaption><span>surface</span>" + escapeHTML(item.id) + "</figcaption>" +
              '<div class="replay-stage">' + state.surfaces[item.id] + "</div></figure>"
            );
          }
          return '<p class="chat-item chat-deleted"><span>deleteSurface</span>' + escapeHTML(item.id) + "</p>";
        })
        .join("");
    }

    function entryHTML(entry, isCurrent) {
      var from = entry.dir === "in" ? "agent" : "renderer";
      return (
        '<li class="log-entry from-' + from + (isCurrent ? " is-current" : "") + '">' +
        "<details" + (isCurrent ? " open" : "") + ">" +
        '<summary><span class="log-from">' + from + "</span>" +
        '<span class="log-kind">' + escapeHTML(entry.kind) + "</span>" +
        '<span class="log-note">' + escapeHTML(entry.note || "") + "</span></summary>" +
        "<pre><code>" + highlight(JSON.stringify(entry.message, null, 2)) + "</code></pre>" +
        "</details></li>"
      );
    }

    // The surfaces are a recording: nothing in them takes focus or input.
    function freeze() {
      each(
        "input, textarea, select, button, a",
        function (element) {
          element.tabIndex = -1;
          if ("readOnly" in element) element.readOnly = true;
        },
        chat
      );
    }

    function target(move) {
      return move && move.target ? chat.querySelector(move.target) : null;
    }

    function scrollChat(top, smooth) {
      chat.scrollTo({ top: Math.max(0, top), behavior: smooth && !reducedMotion.matches ? "smooth" : "auto" });
    }

    // Scrolls the conversation as little as it takes to show element.
    function reveal(element, smooth) {
      var box = chat.getBoundingClientRect();
      var rect = element.getBoundingClientRect();
      if (rect.top < box.top + 16) {
        scrollChat(chat.scrollTop + rect.top - box.top - 16, smooth);
      } else if (rect.bottom > box.bottom - 16) {
        scrollChat(chat.scrollTop + Math.min(rect.bottom - box.bottom + 16, rect.top - box.top - 16), smooth);
      }
    }

    function hint() {
      each(".replay-hint", function (element) { element.classList.remove("replay-hint"); }, chat);
      var element = target(replays[current].steps[index].next);
      if (!element || playing) return;
      var marked = element.type === "checkbox" ? element.closest("label") || element : element;
      marked.classList.add("replay-hint");
    }

    function updateNext() {
      var replay = replays[current];
      var last = index >= replay.steps.length - 1;
      var mode = "next";
      var label;

      if (replay.autoplay) {
        if (playing) {
          mode = "pause";
          label = "Pause";
        } else if (last) {
          mode = "again";
          label = "Play again";
        } else {
          mode = "play";
          label = index === 0 ? "Play the stream" : "Play";
        }
      } else if (last) {
        mode = "again";
        label = "Start again";
      } else {
        label = replay.steps[index].next.text;
      }

      next.setAttribute("data-mode", mode);
      nextLabel.textContent = label;
    }

    function render(options) {
      options = options || {};
      var replay = replays[current];
      var step = replay.steps[index];
      var state = view(replay, index);
      var keep = chat.scrollTop;

      chat.innerHTML = chatHTML(state);
      freeze();
      chat.scrollTop = keep;

      log.innerHTML = state.entries
        .map(function (item) {
          return entryHTML(item.entry, item.step === index);
        })
        .join("");
      var from = { in: 0, out: 0 };
      state.entries.forEach(function (item) {
        from[item.entry.dir] += 1;
      });
      counts.textContent = "agent " + from.in + " · renderer " + from.out;

      var first = log.querySelector(".is-current");
      if (first) log.scrollTop += first.getBoundingClientRect().top - log.getBoundingClientRect().top;
      else log.scrollTop = log.scrollHeight;

      stream.hidden = !replay.autoplay;
      if (replay.autoplay) {
        var before = state.stream.slice(0, state.stream.length - state.chunk.length);
        streamText.innerHTML = escapeHTML(before) + (state.chunk ? "<mark>" + escapeHTML(state.chunk) + "</mark>" : "");
        streamText.scrollTop = streamText.scrollHeight;
        clock.textContent = (((step.at || 0) * pace) / 1000).toFixed(2) + " s";
      }

      caption.textContent = state.caption;
      position.textContent = (replay.autoplay ? "chunk " : "step ") + (index + 1) + " / " + replay.steps.length;
      back.disabled = index === 0;
      forward.hidden = !replay.autoplay;
      forward.disabled = index >= replay.steps.length - 1;
      updateNext();

      if (options.moved && !options.playback) {
        each(
          ".chat-surface",
          function (figure) {
            if (step.surfaces && step.surfaces[figure.getAttribute("data-surface")] !== undefined) {
              figure.classList.add("is-changed");
            }
          },
          chat
        );
        later(function () {
          each(".is-changed", function (figure) { figure.classList.remove("is-changed"); }, chat);
        }, 1200);
      }

      // Follow a stream; after a move, show the first new item, or else
      // the element of the next move.
      var element = target(step.next);
      var fresh = options.moved && state.chat.length > shown ? chat.children[shown] : null;
      if (options.playback) {
        chat.scrollTop = chat.scrollHeight;
      } else if (fresh) {
        scrollChat(chat.scrollTop + fresh.getBoundingClientRect().top - chat.getBoundingClientRect().top - 16, true);
      } else if (options.moved && element) {
        reveal(element, true);
      }
      shown = state.chat.length;
      hint();
    }

    function go(at, moved) {
      stop();
      index = Math.max(0, Math.min(at, replays[current].steps.length - 1));
      render({ moved: moved });
    }

    // Acts out a move (typing, a click, the agent at work), then calls done.
    function act(move, done) {
      var element = target(move);
      var finished = false;

      function finish() {
        if (finished) return;
        finished = true;
        timers.forEach(window.clearTimeout);
        timers = [];
        moving = null;
        done();
      }

      if (!move || reducedMotion.matches || (move.do !== "wait" && !element)) {
        finish();
        return;
      }

      moving = { finish: finish };
      each(".replay-hint", function (marked) { marked.classList.remove("replay-hint"); }, chat);

      if (move.do === "wait") {
        chat.insertAdjacentHTML("beforeend", bubble("chat-agent chat-typing", "agent", "<i></i><i></i><i></i>"));
        scrollChat(chat.scrollHeight, true);
        later(finish, 900);
        return;
      }

      reveal(element, true);

      if (move.do === "click") {
        var pressed = element.type === "checkbox" ? element.closest("label") || element : element;
        later(function () { pressed.classList.add("replay-press"); }, 250);
        later(finish, 650);
        return;
      }

      element.classList.add("replay-typing");

      if (element.type === "range") {
        var to = Number(move.value);
        var slider = element.closest(".a2ui-slider");
        var output = slider && slider.querySelector(".a2ui-slider-value");
        var min = Number(element.min || 0);
        var max = Number(element.max || 100);
        var slide = function () {
          var value = Number(element.value);
          if (value === to) {
            later(finish, 400);
            return;
          }
          element.value = value + (to > value ? 1 : -1);
          if (output) output.textContent = element.value;
          if (slider && max > min) {
            var fill = ((Number(element.value) - min) / (max - min)) * 100;
            slider.style.setProperty("--a2ui-slider-fill", Math.round(fill * 100) / 100 + "%");
          }
          later(slide, 90);
        };
        later(slide, 300);
        return;
      }

      var typed = 0;
      var type = function () {
        if (typed >= move.value.length) {
          later(finish, 400);
          return;
        }
        typed += 1;
        element.value = move.value.slice(0, typed);
        later(type, 55);
      };
      element.value = "";
      later(type, 300);
    }

    function play() {
      var replay = replays[current];
      if (index >= replay.steps.length - 1) {
        index = 0;
        render();
      }
      playing = true;
      updateNext();
      hint();

      var frame = function () {
        if (index >= replay.steps.length - 1) {
          playing = false;
          updateNext();
          return;
        }
        later(function () {
          index += 1;
          render({ moved: true, playback: true });
          frame();
        }, (replay.steps[index + 1].at - replay.steps[index].at) * pace);
      };
      frame();
    }

    function pause() {
      stop();
      updateNext();
    }

    function advance() {
      var replay = replays[current];
      if (replay.autoplay) {
        if (playing) pause();
        else play();
        return;
      }
      if (moving) {
        moving.finish();
        return;
      }
      if (index >= replay.steps.length - 1) {
        chat.scrollTop = 0;
        go(0, false);
        return;
      }
      act(replay.steps[index].next, function () {
        go(index + 1, true);
      });
    }

    function select(at, focus) {
      stop();
      current = at;
      index = 0;
      tabs.forEach(function (tab, other) {
        tab.setAttribute("aria-selected", String(other === at));
        tab.tabIndex = other === at ? 0 : -1;
      });
      panel.setAttribute("aria-labelledby", tabs[at].id);
      var strip = tabs[at].parentNode.getBoundingClientRect();
      var box = tabs[at].getBoundingClientRect();
      if (box.left < strip.left || box.right > strip.right) tabs[at].parentNode.scrollLeft += box.left - strip.left - 8;
      source.textContent = replays[at].source;
      summary.textContent = replays[at].summary;
      if (focus) tabs[at].focus();
      chat.scrollTop = 0;
      render();
      if (replays[at].autoplay && !reducedMotion.matches) play();
    }

    tabs.forEach(function (tab, at) {
      tab.addEventListener("click", function () {
        if (at !== current) select(at, false);
      });
      tab.addEventListener("keydown", function (event) {
        var to = null;
        if (event.key === "ArrowRight") to = (at + 1) % tabs.length;
        if (event.key === "ArrowLeft") to = (at - 1 + tabs.length) % tabs.length;
        if (event.key === "Home") to = 0;
        if (event.key === "End") to = tabs.length - 1;
        if (to !== null) {
          event.preventDefault();
          select(to, true);
        }
      });
    });

    next.addEventListener("click", advance);
    back.addEventListener("click", function () {
      go(index - 1, false);
    });
    forward.addEventListener("click", function () {
      go(index + 1, true);
    });
    restart.addEventListener("click", function () {
      chat.scrollTop = 0;
      go(0, false);
      if (replays[current].autoplay && !reducedMotion.matches) play();
    });

    // Inside a surface, only the element the next move names responds,
    // and acts the move out.
    chat.addEventListener("submit", function (event) {
      event.preventDefault();
    });
    chat.addEventListener("mousedown", function (event) {
      if (event.target.closest("input, textarea, select, button")) event.preventDefault();
    });
    chat.addEventListener("click", function (event) {
      var hit = event.target.closest("button, input, textarea, select, label, a");
      if (!hit) return;
      event.preventDefault();
      var element = target(replays[current].steps[index].next);
      if (!element || moving || playing) return;
      if (hit === element || hit.contains(element) || element.contains(hit) || (hit.htmlFor && hit.htmlFor === element.id)) {
        advance();
      }
    });

    render();
  }

  initTheme();
  initHeader();
  initActiveSection();
  initTabs();
  initCopy();
  initReveal();
  initSpotlight();
  initDemo();
  initReplays();
})();
