import {ThreadComposer} from "./thread_composer.js";
import {ArtifactFrame} from "./artifact_frame.js";
import {AndroidDisplay} from "./android_display.js";
import {WorkspaceNavigation, MachineConnection} from "./workspace.js";
import {readPalette} from "./palette.js";
import {adjustMediaPadding, offGridElements, setGridDebug} from "./grid.js";
import {PasskeyCeremony} from "./passkey";
import {AdminElevation} from "./admin_elevation";
import "./appearance.js";
import {installLocaleReload} from "./localization.js";
import {captureRepositoryLaunch, RepositoryLaunchComplete} from "./repository_launch.js";
import {initBrowserExtensionPresence} from "./browser_extension_presence.js";
// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"
// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.
// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html";
// Establish Phoenix Socket and LiveView configuration.
import { Socket } from "phoenix";
import { LiveSocket } from "phoenix_live_view";
import { hooks as colocatedHooks } from "phoenix-colocated/marshall";
import topbar from "../vendor/topbar";
import { TerminalWorkspace } from "./terminals.js";
import { DashboardVisibility } from "./dashboard.js";
const csrfToken = document
  .querySelector("meta[name='csrf-token']")
  ?.getAttribute("content");
captureRepositoryLaunch(document, window);
initBrowserExtensionPresence(document);
installLocaleReload(window);
/**
 * @cc [owner:ghuntley,label:product] browser-time-zone-connect-param
 * The connect params MUST carry the browser's IANA zone from the Intl API as
 * `timezone` (or null when unavailable) so a user without a saved zone sees
 * times in their browser's zone. The server validates it; it is never stored.
 */
function browserTimeZone() {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || null;
  } catch (_error) {
    return null;
  }
}
/**
 * @cc [owner:ghuntley,label:integration] liveview-hook-and-csrf-registration
 * liveSocket MUST send the page CSRF token and register TerminalWorkspace along
 * with the component/colocated hooks. Asset refactors MUST preserve the hook
 * names referenced by server-rendered templates.
 */
const liveSocket = new LiveSocket("/live", Socket, {
  // No long-poll fallback: replicas share no PubSub (Erlang distribution is
  // off, ADR-0141) and the proxy balances requests round-robin, so a long-poll
  // session cannot survive its next request. Phoenix memorizes a fallback in
  // sessionStorage, so one slow ping would leave the tab unable to join.
  heartbeatIntervalMs: 5000,
  // A reconnecting mount may wait up to 40 s for the database (ADR-0140); a
  // shorter join timeout would turn that wait into a full page reload.
  timeout: 60000,
  params: {
    _csrf_token: csrfToken,
    timezone: browserTimeZone(),
  },
  hooks: {
    ...colocatedHooks,
    TerminalWorkspace,
    AndroidDisplay,
    PasskeyCeremony,
    AdminElevation,
    WorkspaceNavigation,
    MachineConnection,
    DashboardVisibility,
    RepositoryLaunchComplete,
    ThreadComposer,
    ArtifactFrame,
  },
});
// Show progress bar on live navigation and form submits
topbar.config({
  barColors: {
    0: readPalette().text,
  },
  shadowColor: "transparent",
});
window.addEventListener("phx:page-loading-start", (_info) => {
  topbar.config({barColors: {0: readPalette().text}});
  topbar.show(300);
});
window.addEventListener("phx:page-loading-stop", (_info) => {
  topbar.hide();
  adjustMediaPadding(document);
});
window.addEventListener("load", () => adjustMediaPadding(document));
window.addEventListener("resize", () => adjustMediaPadding(document));
// Character-grid diagnostics for the browser probe and manual review:
// window.overallsGrid.check() lists off-grid elements; .debug(true) overlays the grid.
window.overallsGrid = {
  check: () => offGridElements(document),
  debug: (enabled = true) => setGridDebug(document, enabled),
};
// connect if there are any LiveViews on the page
if (csrfToken) liveSocket.connect();
// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket;
// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener(
    "phx:live_reload:attached",
    ({ detail: reloader }) => {
      // Enable server log streaming to client.
      // Disable with reloader.disableServerLogs()
      reloader.enableServerLogs();
      // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
      //
      //   * click with "c" key pressed to open at caller location
      //   * click with "d" key pressed to open at function component definition location
      let keyDown;
      window.addEventListener("keydown", (e) => (keyDown = e.key));
      window.addEventListener("keyup", (_e) => (keyDown = null));
      window.addEventListener(
        "click",
        (e) => {
          if (keyDown === "c") {
            e.preventDefault();
            e.stopImmediatePropagation();
            reloader.openEditorAtCaller(e.target);
          } else if (keyDown === "d") {
            e.preventDefault();
            e.stopImmediatePropagation();
            reloader.openEditorAtDef(e.target);
          }
        },
        true,
      );
      window.liveReloader = reloader;
    },
  );
}
