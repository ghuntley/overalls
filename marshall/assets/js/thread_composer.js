// @ts-check

/** @typedef {{el: HTMLElement, pushEvent: (event: string, payload: Record<string, unknown>) => void, handleEvent: (event: string, callback: (payload: unknown) => void) => void, controller?: AbortController, composer?: HTMLTextAreaElement, returnFocus?: HTMLElement, choice: number, composing: boolean, detailDialogOpen?: boolean, paletteOpen?: boolean, paletteQuery?: string, paletteOrigin?: "button" | "slash"}} ComposerHook */

/**
 * @cc [owner:ghuntley,label:product] composer-command-prefix
 * A command MUST begin at the first character. Leading whitespace preserves
 * literal text, and completion MUST NOT submit a form or create a thread.
 * @param {string} value
 * @returns {string | null}
 */
export function commandPrefix(value) {
  return /^\/[a-z]*$/.test(value) ? value.slice(1) : null;
}

/** @param {ComposerHook} hook @returns {void} */
function refreshCommandAvailability(hook) {
  const state = hook.el.dataset;
  hook.el.querySelectorAll("button[data-thread-command]").forEach(button => {
    if (!(button instanceof HTMLButtonElement)) return;
    const command = button.dataset.threadCommand;
    let allowed = command === "help";
    if (command === "plan" || command === "work") allowed = state.threadNew === "true" || (state.threadWrite === "true" && state.threadReady === "true" && state.threadBusy !== "true");
    if (command === "context" || command === "skills") allowed = state.threadSelected === "true";
    if (command === "compact") allowed = state.threadWrite === "true" && state.threadReady === "true" && state.threadBusy !== "true";
    if (command === "share") allowed = state.threadManage === "true";
    if (command === "terminal") allowed = state.threadWrite === "true" && state.threadReady === "true";
    if (command === "code") allowed = state.threadEditor === "true";
    button.disabled = !allowed;
  });
}

/** @param {ComposerHook} hook @returns {HTMLDialogElement | null} */
function palette(hook) {
  return hook.el.querySelector("#thread-command-palette");
}

/** @param {ComposerHook} hook @returns {HTMLButtonElement[]} */
function choices(hook) {
  const container = palette(hook)?.open ? palette(hook) : hook.el.querySelector("[data-thread-completions]:not([hidden])") || hook.el.querySelector("#thread-skill-suggestions");
  return container ? Array.from(container.querySelectorAll("button[data-thread-command]:not([hidden]):not([disabled]), button[data-thread-skill]:not([disabled])")) : [];
}

/** @param {ComposerHook} hook @returns {void} */
function highlight(hook) {
  const buttons = choices(hook);
  hook.choice = Math.max(0, Math.min(hook.choice, buttons.length - 1));
  const input = palette(hook)?.open ? hook.el.querySelector("#thread-command-search") : hook.composer;
  input?.removeAttribute("aria-activedescendant");
  buttons.forEach((button, index) => {
    button.setAttribute("aria-selected", String(index === hook.choice));
    if (index === hook.choice) {
      input?.setAttribute("aria-activedescendant", button.id);
    }
  });
}

/** @param {ComposerHook} hook @returns {void} */
function hideCompletions(hook) {
  hook.el.querySelectorAll("[data-thread-completions]").forEach(el => el.setAttribute("hidden", ""));
  hook.composer?.setAttribute("aria-expanded", "false");
  hook.composer?.removeAttribute("aria-activedescendant");
}

/** @param {ComposerHook} hook @param {string} query @param {boolean} resetChoice @returns {void} */
function filter(hook, query, resetChoice = true) {
  hook.paletteQuery = query;
  const container = palette(hook)?.open ? palette(hook) : hook.el.querySelector("[data-thread-completions]");
  container?.querySelectorAll("button[data-thread-command]").forEach(button => {
    if (button instanceof HTMLButtonElement) button.hidden = !button.dataset.threadCommand?.startsWith(query.toLowerCase().replace(/^\//, ""));
  });
  if (resetChoice) hook.choice = 0;
  if (palette(hook)?.open) hook.el.querySelector("#thread-command-search")?.setAttribute("aria-expanded", "true");
  highlight(hook);
}

/**
 * @cc [owner:ghuntley,label:product;accessibility] slash-command-palette
 * A slash typed at the command position MUST open the same command palette as
 * the Commands control, seed its search with the command prefix, and preserve
 * the composer draft until a command is explicitly selected. LiveView patches
 * caused by composer validation MUST keep that palette open and restore its
 * current query and focus.
 * @param {ComposerHook} hook
 * @param {HTMLElement | undefined} trigger
 * @param {string} query
 * @param {"button" | "slash"} origin
 * @returns {void}
 */
function openPalette(hook, trigger, query = "", origin = "button") {
  const dialog = palette(hook);
  if (!dialog) return;
  hook.paletteOpen = true;
  hook.paletteQuery = query;
  hook.returnFocus = trigger;
  hook.paletteOrigin = origin;
  hideCompletions(hook);
  if (trigger instanceof HTMLTextAreaElement) trigger.setAttribute("aria-expanded", "true");
  if (!dialog.open) dialog.showModal();
  const search = dialog.querySelector("input");
  if (search) {
    search.value = query;
    search.focus();
  }
  filter(hook, query);
}

/** @param {ComposerHook} hook @returns {void} */
function closePalette(hook) {
  const dialog = palette(hook);
  const composer = hook.composer?.isConnected
    ? hook.composer
    : hook.el.querySelector("textarea[data-thread-input]");
  dialog?.close();
  hook.paletteOpen = false;
  hook.paletteQuery = undefined;
  hook.paletteOrigin = undefined;
  if (composer instanceof HTMLTextAreaElement) composer.setAttribute("aria-expanded", "false");
  dialog?.querySelector("input")?.setAttribute("aria-expanded", "false");
  if (hook.returnFocus?.isConnected) hook.returnFocus.focus();
  else if (composer instanceof HTMLTextAreaElement) composer.focus();
}

/** @param {ComposerHook} hook @param {string} command @param {boolean} complete @returns {void} */
function activate(hook, command, complete) {
  const input = hook.composer?.isConnected
    ? hook.composer
    : hook.el.querySelector("textarea[data-thread-input]");
  if (complete && input instanceof HTMLTextAreaElement) {
    const prefix = commandPrefix(input.value);
    // A slash palette owns the command draft. A palette opened from the
    // toolbar may still be used with an empty composer, but must not discard
    // an unrelated message when Tab is pressed.
    if (hook.paletteOrigin === "slash" || prefix !== null || input.value.trim() === "") {
      input.value = `/${command} `;
      input.dispatchEvent(new Event("input", {bubbles: true}));
    }
    input.focus();
  } else {
    hook.pushEvent("thread_command", {command});
  }
  hideCompletions(hook);
  if (palette(hook)?.open) closePalette(hook);
}

/**
 * @cc [owner:ghuntley,label:product;accessibility] palette-patch-persistence
 * While the palette is open, a LiveView patch MUST restore its modal state,
 * current search query, filtered choices, active choice and search focus before
 * the next composer keystroke.
 * @param {ComposerHook} hook
 * @returns {void}
 */
function restorePalette(hook) {
  const dialog = palette(hook);
  if (!hook.paletteOpen || !dialog) return;

  // A composer `phx-change` patch can reconcile the dialog while it is open.
  // The server intentionally does not render the client-only `open` state, so
  // restore it from the hook before the next keystroke reaches the composer.
  if (!dialog.open) dialog.showModal();
  const composer = hook.composer?.isConnected
    ? hook.composer
    : hook.el.querySelector("textarea[data-thread-input]");
  if (composer instanceof HTMLTextAreaElement) composer.setAttribute("aria-expanded", "true");
  const search = dialog.querySelector("input");
  if (search instanceof HTMLInputElement) {
    const query = hook.paletteQuery || "";
    search.value = query;
    search.focus();
    filter(hook, query, false);
  }
}

/** @param {ComposerHook} hook @returns {void} */
function bindTerminalDisclosure(hook) {
  hook.el.querySelectorAll("details[data-thread-terminal]").forEach(details => {
    if (!(details instanceof HTMLDetailsElement)) return;
    const load = () => {
      if (!details.open) return;
      const frame = details.querySelector("iframe[data-thread-terminal-src]");
      if (!(frame instanceof HTMLIFrameElement) || frame.hasAttribute("src")) return;
      const source = frame.dataset.threadTerminalSrc;
      if (source) frame.src = source;
    };
    if (details.dataset.threadTerminalBound !== "true") {
      details.dataset.threadTerminalBound = "true";
      details.addEventListener("toggle", load, {signal: hook.controller?.signal});
    }
    load();
  });
}

/**
 * @cc [owner:ghuntley,label:product;security] composer-browser-controls
 * Keyboard shortcuts MUST be scoped to the composer or its dialog, preserve
 * drafts on Escape, and ignore IME composition. Browser actions MUST only send
 * command identities; the server rechecks permission and operation eligibility.
 */
export const ThreadComposer = {
  /** @this {ComposerHook} @returns {void} */
  mounted() {
    this.controller = new AbortController();
    this.choice = 0;
    this.composing = false;
    refreshCommandAvailability(this);
    bindTerminalDisclosure(this);
    const signal = this.controller.signal;
    this.el.addEventListener("compositionstart", () => { this.composing = true; }, {signal});
    this.el.addEventListener("compositionend", () => { this.composing = false; }, {signal});
    this.el.addEventListener("focusin", event => {
      if (event.target instanceof HTMLTextAreaElement && event.target.matches("[data-thread-input]")) this.composer = event.target;
    }, {signal});
    this.el.addEventListener("input", event => {
      const target = event.target;
      if (this.composing) return;
      if (target instanceof HTMLInputElement && target.id === "thread-command-search") {
        filter(this, target.value); return;
      }
      if (!(target instanceof HTMLTextAreaElement) || !target.matches("[data-thread-input]")) return;
      this.composer = target;
      const prefix = commandPrefix(target.value);
      hideCompletions(this);
      if (prefix !== null) {
        if (!palette(this)?.open) openPalette(this, target, prefix, "slash");
      }
      if (/(?:^|\s)\$[^\s]*$/.test(target.value)) this.pushEvent("skill_search", {query: target.value.split("$").at(-1) || ""});
    }, {signal});
    this.el.addEventListener("click", event => {
      const target = event.target instanceof Element ? event.target.closest("button") : null;
      if (!(target instanceof HTMLButtonElement)) return;
      if (target.hasAttribute("data-thread-commands-open")) openPalette(this, target);
      if (target.hasAttribute("data-thread-commands-close")) closePalette(this);
      const command = target.dataset.threadCommand;
      if (command && !target.disabled) activate(this, command, false);
    }, {signal});
    this.el.addEventListener("keydown", event => {
      if (this.composing || event.isComposing) return;
      const target = event.target;
      const inComposer = target instanceof HTMLTextAreaElement && target.matches("[data-thread-input]");
      const inPalette = palette(this)?.open && target instanceof Node && palette(this)?.contains(target);
      if (!inComposer && !inPalette) return;
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k" && inComposer) {
        event.preventDefault(); openPalette(this, target); return;
      }
      const buttons = choices(this);
      if (event.key === "Escape") {
        if (inPalette) { event.preventDefault(); closePalette(this); }
        else { hideCompletions(this); this.pushEvent("dismiss_skill_search", {}); }
        return;
      }
      if (!buttons.length) return;
      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        event.preventDefault();
        this.choice = (this.choice + (event.key === "ArrowDown" ? 1 : -1) + buttons.length) % buttons.length;
        highlight(this);
      } else if (event.key === "Enter" || event.key === "Tab") {
        if (
          target instanceof HTMLButtonElement &&
          !target.dataset.threadCommand &&
          !target.dataset.threadSkill
        ) return;
        event.preventDefault();
        const selected = target instanceof HTMLButtonElement ? target : buttons[this.choice];
        const command = selected?.dataset.threadCommand;
        const skill = selected?.dataset.threadSkill;
        if (command) activate(this, command, event.key === "Tab");
        if (skill) this.pushEvent("select_skill", {id: skill});
      }
    }, {signal});
    palette(this)?.addEventListener("cancel", event => { event.preventDefault(); closePalette(this); }, {signal});
    this.handleEvent("thread-composer-clear", () => {
      this.el.querySelectorAll("textarea[data-thread-input]").forEach(input => {
        if (input instanceof HTMLTextAreaElement) { input.value = ""; input.dispatchEvent(new Event("input", {bubbles: true})); }
      });
      hideCompletions(this);
    });
    this.handleEvent("thread-skill-selected", () => {
      if (!this.composer) return;
      this.composer.value = this.composer.value.replace(/(^|\s)\$[^\s]*$/, "$1");
      this.composer.dispatchEvent(new Event("input", {bubbles: true}));
      this.composer.focus();
    });
    this.handleEvent("thread-focus-composer", () => {
      const input = this.el.querySelector("textarea[data-thread-input]");
      if (input instanceof HTMLTextAreaElement) input.focus();
    });
  },
  /** @this {ComposerHook} @returns {void} */
  updated() {
    refreshCommandAvailability(this);
    bindTerminalDisclosure(this);
    restorePalette(this);
    const dialog = this.el.querySelector("dialog[data-thread-dialog]");
    if (dialog instanceof HTMLDialogElement && !dialog.open) {
      this.returnFocus = document.activeElement instanceof HTMLElement ? document.activeElement : this.composer;
      this.detailDialogOpen = true;
      dialog.showModal();
      dialog.addEventListener("cancel", event => {
        event.preventDefault();
        this.pushEvent("close_thread_dialog", {});
      }, {once: true});
    } else if (!dialog && this.detailDialogOpen) {
      this.detailDialogOpen = false;
      if (this.returnFocus?.isConnected) this.returnFocus.focus();
      else this.composer?.focus();
    }
    if (this.el.querySelector("#thread-skill-suggestions")) highlight(this);
  },
  /** @this {ComposerHook} @returns {void} */
  destroyed() { this.controller?.abort(); },
};
