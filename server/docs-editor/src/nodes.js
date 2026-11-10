// Planning visuals for docs (MF-363, docs/planning-docs.md): Mermaid diagrams, tables, charts drawn from the
// table above them, R2 images and file attachments, callouts and toggles, and live task embeds.
// The schema parts load in Node (the Markdown tests); node views only run in the browser.
//
// Host callbacks come in through one `host` object, shared by every node view of an editor:
//   tasks(): full task objects {id, title, state, pr {number, url, state}, assignee, goal}
//   docId
//   onEvent(name, data): openTask {id}
//   mermaidPage: the diagram page URL
//   listeners: redraw callbacks, run by the editor's tasksChanged()
import { Node, mergeAttributes } from "@tiptap/core";
import { DecisionEmbed } from "./decisions.js";
import { Table, TableRow, TableHeader, TableCell } from "@tiptap/extension-table";

export const CALLOUT_TONES = ["note", "tip", "warning", "important"];
export const IMAGE_MIME = ["image/png", "image/jpeg", "image/gif", "image/webp"];

/** What an uploaded file becomes: an image node for png/jpeg/gif/webp (never SVG, which can carry scripts),
 *  otherwise a file chip. `result` is POST /api/attachments's reply {path, name, mime, size}. */
export function nodeForUpload(result) {
  const mime = String(result.mime ?? "").toLowerCase();
  const ext = String(result.name ?? "").toLowerCase().split(".").pop();
  const svg = mime.includes("svg") || ext === "svg";
  if (!svg && IMAGE_MIME.includes(mime)) return { type: "image", attrs: { src: result.path, alt: result.name ?? "", width: null } };
  return { type: "fileAttachment", attrs: { href: result.path, name: result.name ?? "file", size: result.size ?? null, mime: mime || null } };
}

/** A table node's data as a chart: the first row names the series, the first column labels the points, and
 *  every other column with a number in it is a series. Non-numeric cells are skipped (null). */
export function chartSeries(table) {
  if (!table || table.type.name !== "table") return { labels: [], series: [] };
  const rows = [];
  table.forEach((row) => { const cells = []; row.forEach((c) => cells.push(c.textContent.trim())); rows.push(cells); });
  if (rows.length < 2) return { labels: [], series: [] };
  const [head, ...body] = rows;
  const num = (s) => { const t = s.replace(/[,\s]/g, "").replace(/%$/, ""); return t !== "" && Number.isFinite(+t) ? +t : null; };
  const series = [];
  for (let c = 1; c < head.length; c++) {
    const values = body.map((r) => num(r[c] ?? ""));
    if (values.some((v) => v != null)) series.push({ name: head[c] || `Series ${c}`, values });
  }
  return { labels: body.map((r) => r[0] ?? ""), series };
}

/** The last table before position `pos` among the doc's top-level blocks. */
export function tableAbove(doc, pos) {
  let found = null;
  doc.forEach((node, offset) => { if (offset < pos && node.type.name === "table") found = node; });
  return found;
}

const el = (tag, attrs = {}, ...kids) => {
  const e = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v == null || v === false) continue;
    if (k.startsWith("on")) e.addEventListener(k.slice(2), v);
    else if (k === "class") e.className = v;
    else e.setAttribute(k, v === true ? "" : v);
  }
  for (const k of kids.flat()) if (k != null && k !== false) e.append(k.nodeType ? k : String(k));
  return e;
};
const svgEl = (tag, attrs = {}) => {
  const e = document.createElementNS("http://www.w3.org/2000/svg", tag);
  for (const [k, v] of Object.entries(attrs)) e.setAttribute(k, v);
  return e;
};
const fmtSize = (n) => (n == null ? "" : n < 1024 ? `${n} B` : n < 1048576 ? `${(n / 1024).toFixed(0)} KB` : `${(n / 1048576).toFixed(1)} MB`);
const setAttrs = (editor, getPos, attrs) => {
  const pos = getPos();
  if (typeof pos !== "number") return;
  const node = editor.state.doc.nodeAt(pos);
  if (node) editor.view.dispatch(editor.state.tr.setNodeMarkup(pos, null, { ...node.attrs, ...attrs }));
};
const themeOf = (dom) => dom.closest?.(".doc-editor")?.dataset.theme || "light";
const subscribe = (host, fn) => { host?.listeners?.add(fn); return () => host?.listeners?.delete(fn); };
const findTask = (host, id) => (id ? host?.tasks?.().find((t) => t.id === id) : null);
// A node view's own controls (inputs, buttons) keep their events from ProseMirror.
const ownEvent = (e) => !!e.target.closest?.("input, textarea, select, button, [data-own]");

/** A task card's state pill, PR link and owner. */
function taskCard(task, id, host) {
  if (!task) return el("div", { class: "doc-embed-body" }, el("span", { class: "doc-embed-id" }, id), el("span", { class: "doc-embed-title muted" }, "Not in the feed"));
  const owner = task.assignee ? host?.members?.().find((m) => m.login === task.assignee) : null;
  return el("div", { class: "doc-embed-body" },
    el("span", { class: "doc-embed-id" }, task.id),
    el("span", { class: "doc-embed-title" }, task.title ?? ""),
    el("span", { class: `doc-pill state-${task.state ?? "unknown"}`, "data-state": task.state ?? "" }, task.state ?? "unknown"),
    task.pr?.number ? el("a", { class: "doc-embed-pr", href: task.pr.url ?? "#", target: "_blank", rel: "noopener", "data-own": true }, `PR #${task.pr.number}`) : null,
    task.assignee ? el("span", { class: "doc-embed-owner", title: `@${task.assignee}` },
      owner?.avatar ? el("img", { src: owner.avatar, alt: "" }) : el("span", { class: "doc-avatar" }, task.assignee.slice(0, 1).toUpperCase()),
      `@${task.assignee}`) : null);
}

export const Mermaid = Node.create({
  name: "mermaid",
  group: "block",
  atom: true,
  selectable: true,
  draggable: true,
  addOptions: () => ({ host: null }),
  addAttributes: () => ({ source: { default: "", parseHTML: (e) => e.getAttribute("data-source") ?? e.textContent } }),
  parseHTML: () => [{ tag: "div[data-type=mermaid]" }],
  renderHTML: ({ node }) => ["div", { "data-type": "mermaid", "data-source": node.attrs.source, class: "doc-mermaid" }, ["pre", {}, node.attrs.source]],
  addNodeView() {
    const host = this.options.host;
    return ({ node, editor, getPos }) => {
      let current = node;
      const page = new URL(host?.mermaidPage ?? "/app/mermaid/diagram.html", host?.origin ?? location.origin).href;
      const source = el("textarea", { class: "doc-mermaid-source", spellcheck: "false", "aria-label": "Mermaid source", rows: 8 });
      source.value = node.attrs.source;
      const frame = el("iframe", { class: "doc-mermaid-frame", sandbox: "allow-scripts", src: `${page}?mode=inline`, title: "Diagram", referrerpolicy: "no-referrer" });
      const draw = () => frame.contentWindow?.postMessage({ type: "maple.diagram", source: current.attrs.source, mode: "inline", theme: themeOf(dom) }, "*");
      frame.addEventListener("load", draw);
      const open = () => {
        const big = el("iframe", { class: "doc-mermaid-viewer", sandbox: "allow-scripts", src: `${page}?mode=viewer`, title: "Diagram viewer", referrerpolicy: "no-referrer" });
        const shade = el("div", { class: "doc-overlay" }, big, el("button", { class: "doc-overlay-close", type: "button", "aria-label": "Close", onclick: () => close() }, "×"));
        const onMsg = (e) => { if (e.source === big.contentWindow && e.data?.type === "maple.diagram.state" && e.data.event === "close") close(); };
        const onKey = (e) => { if (e.key === "Escape") close(); };
        const close = () => { shade.remove(); removeEventListener("message", onMsg); removeEventListener("keydown", onKey); };
        big.addEventListener("load", () => big.contentWindow?.postMessage({ type: "maple.diagram", source: current.attrs.source, mode: "viewer", theme: themeOf(dom) }, "*"));
        addEventListener("message", onMsg); addEventListener("keydown", onKey);
        document.body.append(shade);
      };
      let timer;
      source.addEventListener("input", () => { clearTimeout(timer); timer = setTimeout(() => setAttrs(editor, getPos, { source: source.value }), 350); });
      const dom = el("div", { class: "doc-mermaid", "data-type": "mermaid", contenteditable: "false" },
        el("div", { class: "doc-block-label" }, "Diagram", el("button", { type: "button", class: "doc-mini", onclick: open }, "Open")),
        el("div", { class: "doc-mermaid-split" }, source,
          el("div", { class: "doc-mermaid-preview" }, frame, el("button", { type: "button", class: "doc-mermaid-hit", "aria-label": "Open diagram", onclick: open }))));
      return {
        dom,
        update(next) {
          if (next.type !== current.type) return false;
          const changed = next.attrs.source !== current.attrs.source;
          current = next;
          if (changed) { if (document.activeElement !== source) source.value = next.attrs.source; draw(); }
          return true;
        },
        stopEvent: ownEvent,
        ignoreMutation: () => true,
        destroy: () => clearTimeout(timer),
      };
    };
  },
});

export const Chart = Node.create({
  name: "chart",
  group: "block",
  atom: true,
  selectable: true,
  draggable: true,
  addOptions: () => ({ host: null }),
  addAttributes: () => ({
    kind: { default: "bar", parseHTML: (e) => (e.getAttribute("data-kind") === "line" ? "line" : "bar") },
    title: { default: "", parseHTML: (e) => e.getAttribute("data-title") ?? "" },
  }),
  parseHTML: () => [{ tag: "div[data-type=chart]" }],
  renderHTML: ({ node }) => ["div", { "data-type": "chart", "data-kind": node.attrs.kind, "data-title": node.attrs.title, class: "doc-chart" }],
  addNodeView() {
    return ({ node, editor, getPos }) => {
      let current = node;
      const title = el("input", { class: "doc-chart-title", placeholder: "Chart title", "aria-label": "Chart title" });
      title.value = node.attrs.title;
      title.addEventListener("change", () => setAttrs(editor, getPos, { title: title.value }));
      const kinds = ["bar", "line"].map((k) => el("button", { type: "button", class: "doc-mini", "data-kind": k, onclick: () => setAttrs(editor, getPos, { kind: k }) }, k === "bar" ? "Bar" : "Line"));
      const canvas = el("div", { class: "doc-chart-canvas" });
      const dom = el("div", { class: "doc-chart", "data-type": "chart", contenteditable: "false" },
        el("div", { class: "doc-block-label" }, "Chart", title, ...kinds), canvas);
      let last = "";
      const redraw = () => {
        const pos = getPos();
        const data = typeof pos === "number" ? chartSeries(tableAbove(editor.state.doc, pos)) : { labels: [], series: [] };
        const key = JSON.stringify([current.attrs.kind, data]);
        kinds.forEach((b) => b.classList.toggle("on", b.dataset.kind === current.attrs.kind));
        if (key === last) return;
        last = key;
        canvas.replaceChildren(drawChart(current.attrs.kind, data));
      };
      editor.on("update", redraw);
      queueMicrotask(redraw);
      return {
        dom,
        update(next) {
          if (next.type !== current.type) return false;
          current = next;
          if (document.activeElement !== title) title.value = next.attrs.title;
          redraw();
          return true;
        },
        stopEvent: ownEvent,
        ignoreMutation: () => true,
        destroy: () => editor.off("update", redraw),
      };
    };
  },
});

/** An inline SVG bar or line chart: no library, no network. */
export function drawChart(kind, { labels, series }) {
  if (!series.length) return el("div", { class: "doc-chart-empty" }, "Put a table with numbers above this chart: first column labels, then a column per series.");
  const W = 560, H = 240, L = 44, R = 12, T = 12, B = 34;
  const vals = series.flatMap((s) => s.values).filter((v) => v != null);
  const max = Math.max(0, ...vals), min = Math.min(0, ...vals);
  const span = max - min || 1;
  const y = (v) => T + (H - T - B) * (1 - (v - min) / span);
  const svg = svgEl("svg", { viewBox: `0 0 ${W} ${H}`, class: "doc-chart-svg", role: "img", "aria-label": `${kind} chart` });
  for (let i = 0; i <= 4; i++) {
    const v = min + (span * i) / 4;
    svg.append(svgEl("line", { x1: L, x2: W - R, y1: y(v), y2: y(v), class: "grid" }));
    const t = svgEl("text", { x: L - 6, y: y(v) + 4, "text-anchor": "end", class: "tick" }); t.textContent = +v.toFixed(2); svg.append(t);
  }
  const band = (W - L - R) / Math.max(1, labels.length);
  labels.forEach((lab, i) => {
    const t = svgEl("text", { x: L + band * (i + 0.5), y: H - B + 18, "text-anchor": "middle", class: "tick" }); t.textContent = lab; svg.append(t);
  });
  series.forEach((s, si) => {
    const cls = `s${si % 6}`;
    if (kind === "line") {
      const pts = s.values.map((v, i) => (v == null ? null : [L + band * (i + 0.5), y(v)])).filter(Boolean);
      svg.append(svgEl("polyline", { points: pts.map((p) => p.join(",")).join(" "), class: `line ${cls}` }));
      pts.forEach(([cx, cy]) => svg.append(svgEl("circle", { cx, cy, r: 3.5, class: `dot ${cls}` })));
    } else {
      const bw = (band * 0.7) / series.length;
      s.values.forEach((v, i) => {
        if (v == null) return;
        const x = L + band * i + band * 0.15 + bw * si;
        svg.append(svgEl("rect", { x, y: Math.min(y(v), y(0)), width: Math.max(1, bw - 2), height: Math.abs(y(v) - y(0)), rx: 2, class: `bar ${cls}` }));
      });
    }
  });
  const legend = el("div", { class: "doc-chart-legend" }, series.map((s, si) => el("span", { class: `s${si % 6}` }, el("i"), s.name)));
  return el("div", {}, svg, legend);
}

export const Image = Node.create({
  name: "image",
  group: "block",
  atom: true,
  draggable: true,
  addAttributes: () => ({
    src: { default: null, parseHTML: (e) => e.querySelector("img")?.getAttribute("src") ?? e.getAttribute("src") },
    alt: { default: "", parseHTML: (e) => (e.querySelector("img") ?? e).getAttribute("alt") ?? "" },
    width: { default: null, parseHTML: (e) => +(e.querySelector("img") ?? e).getAttribute("width") || null },
  }),
  parseHTML: () => [{ tag: "figure[data-type=image]" }, { tag: "img[src]" }],
  renderHTML: ({ node }) => ["figure", { "data-type": "image", class: "doc-image" }, ["img", { src: node.attrs.src, alt: node.attrs.alt, ...(node.attrs.width ? { width: node.attrs.width } : {}), draggable: "false" }]],
});

export const FileAttachment = Node.create({
  name: "fileAttachment",
  group: "block",
  atom: true,
  draggable: true,
  addAttributes: () => ({
    href: { default: null, parseHTML: (e) => e.getAttribute("href") },
    name: { default: "file", parseHTML: (e) => e.getAttribute("data-name") ?? e.textContent },
    size: { default: null, parseHTML: (e) => +e.getAttribute("data-size") || null },
    mime: { default: null, parseHTML: (e) => e.getAttribute("data-mime") },
  }),
  parseHTML: () => [{ tag: "a[data-type=file]" }],
  renderHTML: ({ node }) => ["p", { class: "doc-file-row" }, ["a", { "data-type": "file", class: "doc-file", href: node.attrs.href, "data-name": node.attrs.name, "data-size": node.attrs.size, "data-mime": node.attrs.mime, target: "_blank", rel: "noopener" },
    ["span", { class: "doc-file-icon" }, "📎"], ["span", { class: "doc-file-name" }, node.attrs.name], ["span", { class: "doc-file-size" }, fmtSize(node.attrs.size)]]],
});

export const Callout = Node.create({
  name: "callout",
  group: "block",
  content: "block+",
  defining: true,
  addAttributes: () => ({ tone: { default: "note", parseHTML: (e) => (CALLOUT_TONES.includes(e.getAttribute("data-tone")) ? e.getAttribute("data-tone") : "note") } }),
  parseHTML: () => [{ tag: "div[data-type=callout]" }],
  renderHTML: ({ node, HTMLAttributes }) => ["div", mergeAttributes(HTMLAttributes, { "data-type": "callout", "data-tone": node.attrs.tone, class: "doc-callout" }), 0],
  addNodeView() {
    return ({ node, editor, getPos }) => {
      let current = node;
      const label = el("button", { type: "button", class: "doc-callout-tone", contenteditable: "false", title: "Change tone",
        onclick: () => setAttrs(editor, getPos, { tone: CALLOUT_TONES[(CALLOUT_TONES.indexOf(current.attrs.tone) + 1) % CALLOUT_TONES.length] }) });
      const contentDOM = el("div", { class: "doc-callout-body" });
      const dom = el("div", { class: "doc-callout", "data-type": "callout" }, label, contentDOM);
      const sync = () => { dom.dataset.tone = current.attrs.tone; label.textContent = current.attrs.tone[0].toUpperCase() + current.attrs.tone.slice(1); };
      sync();
      return {
        dom, contentDOM,
        update(next) { if (next.type !== current.type) return false; current = next; sync(); return true; },
        stopEvent: (e) => label.contains(e.target),
        ignoreMutation: (m) => m.type !== "selection" && !contentDOM.contains(m.target),
      };
    };
  },
});

export const Toggle = Node.create({
  name: "toggle",
  group: "block",
  content: "block+",
  defining: true,
  addAttributes: () => ({
    summary: { default: "", parseHTML: (e) => e.getAttribute("data-summary") ?? "" },
    open: { default: true, parseHTML: (e) => e.hasAttribute("open") },
  }),
  parseHTML: () => [{ tag: "details[data-type=toggle]", contentElement: "div" }],
  renderHTML: ({ node }) => ["details", { "data-type": "toggle", "data-summary": node.attrs.summary, class: "doc-toggle", ...(node.attrs.open ? { open: "" } : {}) }, ["summary", {}, node.attrs.summary], ["div", {}, 0]],
  addNodeView() {
    return ({ node, editor, getPos }) => {
      let current = node;
      const caret = el("button", { type: "button", class: "doc-toggle-caret", "aria-label": "Toggle", onclick: () => setAttrs(editor, getPos, { open: !current.attrs.open }) }, "▸");
      const summary = el("input", { class: "doc-toggle-summary", placeholder: "Toggle heading", "aria-label": "Toggle heading" });
      summary.addEventListener("change", () => setAttrs(editor, getPos, { summary: summary.value }));
      summary.addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); summary.blur(); } });
      const head = el("div", { class: "doc-toggle-head", contenteditable: "false" }, caret, summary);
      const contentDOM = el("div", { class: "doc-toggle-body" });
      const dom = el("div", { class: "doc-toggle", "data-type": "toggle" }, head, contentDOM);
      const sync = () => { dom.classList.toggle("open", !!current.attrs.open); if (document.activeElement !== summary) summary.value = current.attrs.summary; };
      sync();
      return {
        dom, contentDOM,
        update(next) { if (next.type !== current.type) return false; current = next; sync(); return true; },
        stopEvent: (e) => head.contains(e.target),
        ignoreMutation: (m) => m.type !== "selection" && !contentDOM.contains(m.target),
      };
    };
  },
});

export const TaskEmbed = Node.create({
  name: "taskEmbed",
  group: "block",
  atom: true,
  selectable: true,
  draggable: true,
  addOptions: () => ({ host: null }),
  addAttributes: () => ({ id: { default: null, parseHTML: (e) => e.getAttribute("data-task") } }),
  parseHTML: () => [{ tag: "div[data-type=task-embed]" }],
  renderHTML: ({ node }) => ["div", { "data-type": "task-embed", "data-task": node.attrs.id, class: "doc-embed" }, node.attrs.id ?? ""],
  addNodeView() {
    const host = this.options.host;
    return ({ node }) => {
      let current = node;
      const dom = el("div", { class: "doc-embed", "data-type": "task-embed", contenteditable: "false" });
      let last = "";
      const draw = () => {
        const task = findTask(host, current.attrs.id);
        const key = JSON.stringify([current.attrs.id, task?.title, task?.state, task?.pr, task?.assignee]);
        if (key === last) return;
        last = key;
        dom.dataset.task = current.attrs.id ?? "";
        dom.replaceChildren(taskCard(task, current.attrs.id, host));
      };
      dom.addEventListener("click", (e) => { if (!e.target.closest("a")) host?.onEvent?.("openTask", { id: current.attrs.id }); });
      draw();
      const off = subscribe(host, draw);
      return {
        dom,
        update(next) { if (next.type !== current.type) return false; current = next; draw(); return true; },
        stopEvent: (e) => e.type === "click" || ownEvent(e),
        ignoreMutation: () => true,
        destroy: off,
      };
    };
  },
});

/** The planning-visual extensions, sharing one `host`. */
export function visualExtensions(host = null) {
  return [
    Mermaid.configure({ host }),
    Table.configure({ resizable: true, HTMLAttributes: { class: "doc-table" } }),
    TableRow, TableHeader, TableCell,
    Chart.configure({ host }),
    Image,
    FileAttachment,
    Callout,
    Toggle,
    TaskEmbed.configure({ host }),
    DecisionEmbed.configure({ host }),
  ];
}
