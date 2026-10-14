// Opens the URL an A2UI `openUrl` action asks for. A2UIPhoenix.Live pushes
// it as the "a2ui:open_url" event; LiveView dispatches pushed events on
// window with a "phx:" prefix. The basic catalog's openUrl already allows
// only these schemes; they are checked again here before anything opens.
const A2UI_URL_SCHEMES = ["http:", "https:", "mailto:", "tel:"];

window.addEventListener("phx:a2ui:open_url", (event) => {
  const raw = event.detail && event.detail.url;
  if (typeof raw !== "string" || raw === "") return;

  let url;
  try {
    url = new URL(raw, window.location.href);
  } catch {
    return;
  }

  if (A2UI_URL_SCHEMES.includes(url.protocol)) {
    window.open(url.toString(), "_blank", "noopener,noreferrer");
  }
});
