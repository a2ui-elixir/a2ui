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

  initTheme();
  initHeader();
  initActiveSection();
  initTabs();
  initCopy();
  initReveal();
  initSpotlight();
  initDemo();
})();
