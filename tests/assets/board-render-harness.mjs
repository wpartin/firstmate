// Render a built bearings board's shipped inline script under a minimal DOM
// shim and print what the renderer actually produced, so board behavior is
// asserted through the real template rather than by reading its source.
//
// Usage: node board-render-harness.mjs <built-board.html> [<scenario.json>]
// Prints one JSON document:
//   { stats:[{n,label,active,disabled}], underway:[{title,sub,badges,options}],
//     charted:[{title,sub,badges,pickable,options}], empty, more, error,
//     filtered, shown, modal:{open,actions,confirm}, prompts:[...], staticBanner,
//     disabledControls }
// A scenario is a list of steps run after render, in order:
//   {"click":"stat","label":"<label>"}   click a count card
//   {"click":"options","section":"underway|charted","row":<n>}
//   {"pick":"<action value>"}            choose an action in the open modal
//   {"note":"<text>"}                    type the modal note
//   {"tick":"discard"}                   tick the discard confirmation
//   {"submit":"modal"}                   submit the modal
import { readFileSync } from "node:fs";

const html = readFileSync(process.argv[2], "utf8");

const allNodes = [];
// A small selector matcher: comma lists of `tag`, `.class`, `#id`,
// `[attr]`, `[attr=value]`, and `:checked`, joined without combinators, or a
// descendant pair such as `.bb-decision button`.
const simpleMatch = (n, simple) => {
  const re = /([.#]?[A-Za-z0-9_-]+)|\[([A-Za-z-]+)(?:=([^\]]+))?\]|(:checked)/g;
  let m;
  while ((m = re.exec(simple))) {
    if (m[4]) { if (!n.checked) return false; continue; }
    if (m[2]) {
      const v = n.attributes[m[2]] ?? (m[2] === "name" ? n.name : m[2] === "type" ? n.type : undefined);
      if (v === undefined || (m[3] !== undefined && String(v) !== m[3].replace(/^["']|["']$/g, ""))) return false;
      continue;
    }
    const t = m[1];
    if (t[0] === ".") { if (!n.className.split(/\s+/).includes(t.slice(1))) return false; }
    else if (t[0] === "#") { if (n.id !== t.slice(1)) return false; }
    else if (n.tagName !== t) return false;
  }
  return true;
};
const matches = (n, sel) => sel.split(",").some((part) => {
  const chain = part.trim().split(/\s+/);
  if (!simpleMatch(n, chain[chain.length - 1])) return false;
  let p = n.parentNode;
  for (let i = chain.length - 2; i >= 0; i--) {
    while (p && !simpleMatch(p, chain[i])) p = p.parentNode;
    if (!p) return false;
    p = p.parentNode;
  }
  return true;
});

class Node {
  constructor(tag) {
    this.tagName = tag;
    this.className = "";
    this.children = [];
    this.attributes = {};
    this._text = "";
    this.hidden = false;
    this.disabled = false;
    this.innerHTML = "";
    this.parentNode = null;
    this.type = "";
    this.value = "";
    this.checked = false;
    this.listeners = {};
    this.classList = {
      add: (c) => { if (!this.classList.contains(c)) this.className = (this.className + " " + c).trim(); },
      remove: (c) => { this.className = this.className.split(/\s+/).filter((x) => x && x !== c).join(" "); },
      toggle: (c, on) => {
        const want = on === undefined ? !this.classList.contains(c) : !!on;
        if (want) this.classList.add(c); else this.classList.remove(c);
        return want;
      },
      contains: (c) => this.className.split(/\s+/).includes(c),
    };
    allNodes.push(this);
  }
  getAttribute(k) { return k in this.attributes ? this.attributes[k] : null; }
  removeAttribute(k) { delete this.attributes[k]; }
  querySelector(sel) { return this.querySelectorAll(sel)[0] || null; }
  fire(type) { for (const f of this.listeners[type] || []) f({ preventDefault() {}, target: this }); }
  get textContent() {
    return this.children.length
      ? this.children.map((c) => c.textContent).join("")
      : this._text;
  }
  set textContent(v) { this._text = String(v); this.children = []; }
  appendChild(n) { n.parentNode = this; this.children.push(n); return n; }
  setAttribute(k, v) { this.attributes[k] = v; }
  addEventListener(type, f) { (this.listeners[type] = this.listeners[type] || []).push(f); }
  querySelectorAll(sel) {
    const out = [];
    const walk = (n) => {
      for (const c of n.children) {
        if (matches(c, sel)) out.push(c);
        walk(c);
      }
    };
    walk(this);
    return out;
  }
}

const byId = new Map();
const dataNode = new Node("script");
dataNode.textContent = html
  .split('<script id="bearings-data" type="application/json">')[1]
  .split("</script>")[0];
// BOARD_HARNESS_LIVE=1 renders a `build --static` page as the live board would,
// so the controls can be exercised without starting a Lavish session.
if (process.env.BOARD_HARNESS_LIVE === "1") {
  dataNode.textContent = dataNode.textContent.replace('"static":true', '"static":false');
}
byId.set("bearings-data", dataNode);

// The template's own static sections, so filters have something to show.
const sectionNodes = [...html.matchAll(/<section class="bb-section" data-section="([a-z]+)">/g)].map((m) => {
  const n = new Node("section");
  n.className = "bb-section";
  n.attributes["data-section"] = m[1];
  return n;
});
const mainNode = new Node("main");
mainNode.className = "bb-main";

globalThis.document = {
  querySelectorAll: (sel) => allNodes.filter((n) => matches(n, sel)),
  createElement: (tag) => new Node(tag),
  createTextNode: (text) => { const n = new Node("#text"); n.textContent = text; return n; },
  // Lazily mint any element the page asks for: the shim tracks whatever ids
  // the shipped template actually uses instead of pinning a fixed list.
  getElementById: (id) => {
    if (!byId.has(id)) {
      const n = new Node(id === "bb-modal" ? "dialog" : "div");
      n.id = id;
      new Node("div").appendChild(n);
      byId.set(id, n);
    }
    return byId.get(id);
  },
  querySelector: (sel) => {
    if (sel === ".bb-main") return mainNode;
    const id = "sel:" + sel;
    if (!byId.has(id)) byId.set(id, new Node("div"));
    return byId.get(id);
  },
};
const prompts = [];
globalThis.window = { lavish: { queuePrompt: (text, opts) => prompts.push({ text, data: opts && opts.data }) } };
globalThis.TextEncoder = TextEncoder;

const script = html.slice(html.indexOf("<script>") + "<script>".length, html.lastIndexOf("</script>"));
new Function(script)();

const badgesOf = (row) =>
  row.children
    .filter((c) => c.className.includes("fm-badge"))
    .map((c) => ({ tone: c.className.replace(/.*fm-badge--/, "").trim(), text: c.textContent }));

const strip = byId.get("bb-stats") || new Node("div");
const labelOf = (t) => t.children.find((c) => c.className.includes("bb-stat__label"))?.textContent;
const modal = byId.get("bb-modal") || new Node("dialog");
modal.showModal = () => { modal.attributes.open = ""; };
modal.close = () => { delete modal.attributes.open; };
const rowButtons = (id) =>
  ((byId.get(id) || new Node("div")).children.filter((r) => r.className.split(/\s+/).includes("bb-row")))
    .map((r) => r.children.find((c) => c.className.includes("bb-rowbtn")));
const modalInputs = () => (byId.get("bb-modal-opts") || new Node("div")).querySelectorAll("input");
const scenario = process.argv[3] ? JSON.parse(readFileSync(process.argv[3], "utf8")) : [];
for (const step of scenario) {
  if (step.click === "stat") strip.children.find((t) => labelOf(t) === step.label).fire("click");
  else if (step.click === "options") rowButtons("bb-" + step.section)[step.row].fire("click");
  else if (step.pick) {
    for (const i of modalInputs()) i.checked = i.value === step.pick;
    modalInputs().find((i) => i.value === step.pick).fire("change");
  } else if (step.note !== undefined) byId.get("bb-modal-note").value = step.note;
  else if (step.tick === "discard") byId.get("bb-modal-confirm").querySelector("input").checked = true;
  else if (step.submit === "modal") byId.get("bb-modal-form").fire("submit");
}
const stats = strip.children.map((t) => ({
  n: Number(t.children.find((c) => c.className.includes("bb-stat__num"))?.textContent),
  label: labelOf(t),
  active: t.classList.contains("is-active"),
  disabled: !!t.disabled,
}));

const rowsOf = (container) =>
  container.children
    .filter((r) => r.className.split(/\s+/).includes("bb-row"))
    .map((row) => {
      const main = row.children.find((c) => c.className.includes("bb-row__main"));
      return {
        title: main?.children.find((c) => c.className.includes("bb-row__title"))?.textContent ?? "",
        sub: main?.children.find((c) => c.className.includes("bb-row__sub"))?.textContent ?? "",
        badges: badgesOf(row),
        pickable: row.children.some((c) => c.className.includes("bb-pick") && !c.className.includes("spacer")),
        options: row.children.some((c) => c.className.includes("bb-rowbtn")),
      };
    });

const uw = byId.get("bb-underway") || new Node("div");
const underway = rowsOf(uw);

const ch = byId.get("bb-charted") || new Node("div");
const charted = rowsOf(ch);
// A fail-closed render replaces the page body instead of the board sections, so
// surface it rather than reporting an empty board as a successful render.
const errorText = [...byId.entries()]
  .filter(([k]) => k.startsWith("sel:"))
  .flatMap(([, n]) => n.children.map((c) => c.textContent))
  .concat(mainNode.children.map((c) => c.textContent))
  .join(" ");
const empty = ch.children.filter((c) => c.className.includes("bb-empty")).map((c) => c.textContent);
const more = ch.children.filter((c) => c.className.includes("bb-morechip")).map((c) => c.textContent);

const confirmNode = byId.get("bb-modal-confirm") || new Node("div");
const staticNode = byId.get("bb-static") || new Node("div");
process.stdout.write(
  JSON.stringify({
    stats, underway, charted, empty, more, error: errorText,
    filtered: mainNode.classList.contains("bb-filtered"),
    shown: sectionNodes.filter((n) => n.classList.contains("is-shown")).map((n) => n.attributes["data-section"]),
    modal: {
      open: "open" in modal.attributes,
      actions: modalInputs().map((i) => i.value),
      confirm: confirmNode.hidden ? "" : confirmNode.textContent,
    },
    prompts,
    staticBanner: staticNode.hidden ? "" : staticNode.textContent,
    disabledControls: allNodes.filter((n) => n.disabled && (n.tagName === "button" || n.tagName === "input")).length,
    enabledControls: allNodes.filter((n) => !n.disabled && (n.tagName === "button" || n.tagName === "input")
      && !n.className.includes("bb-stat") && n.id !== "bb-modal-note").length,
  }) + "\n");
