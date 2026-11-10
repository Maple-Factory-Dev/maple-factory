// The docs editor (MF-361, docs/planning-docs.md): TipTap over a Y.Doc whose shared XmlFragment
// `prosemirror` syncs with the doc's DocHub through a y-websocket provider on /docs/<id>/sync.
import { Editor, Extension, InputRule } from "@tiptap/core";
import Collaboration from "@tiptap/extension-collaboration";
import CollaborationCaret from "@tiptap/extension-collaboration-caret";
import BubbleMenu from "@tiptap/extension-bubble-menu";
import { Placeholder } from "@tiptap/extensions";
import { Plugin } from "@tiptap/pm/state";
import * as Y from "yjs";
import { WebsocketProvider } from "y-websocket";
import { prosemirrorToYXmlFragment } from "@tiptap/y-tiptap";
import { Awareness } from "y-protocols/awareness";
import { schema as docSchema, schemaExtensions, TASK_ID } from "./schema.js";
import { markdownPasteSlice, toMarkdown, fromMarkdown, taskResolver } from "./markdown.js";
import { SlashMenu, mentionSuggestions, bubbleMenuElement } from "./menus.js";
import { nodeForUpload } from "./nodes.js";
import { proposeDecision, flash as flashDecision } from "./decisions.js";
import { ensureStarterBlock, STARTER_ORIGIN } from "./starter.js";
import { commentHighlights, createCommentRail, anchorFromRange, resolveAnchor, mappingOf } from "./comments.js";

export { ensureStarterBlock, STARTER_ORIGIN };
export { toMarkdown, fromMarkdown, taskResolver, nodeForUpload, anchorFromRange, resolveAnchor, mappingOf };

export const SHARED_TYPE = "prosemirror";
/** The empty doc's hint, also in editor.css's `p.is-editor-empty::before`. */
export const PLACEHOLDER = "Type / for blocks, @ to mention, # for a task";

const PALETTE = ["#d24e26", "#2f6feb", "#14a866", "#7c5ce0", "#c27c0e", "#0e8fa3", "#d9488f", "#5b6b86"];
/** A member's cursor color: the same for a login everywhere. */
export function colorFor(login = "") {
  let h = 0;
  for (const c of login) h = (h * 31 + c.charCodeAt(0)) >>> 0;
  return PALETTE[h % PALETTE.length];
}

/** Typing `MF-12 ` (a task the resolver knows) turns the id into a live task ref. */
const TaskRefTyping = (tasks) =>
  Extension.create({
    name: "taskRefTyping",
    addInputRules() {
      return [
        new InputRule({
          find: new RegExp(`(?:^|\\s)(${TASK_ID.source})\\s$`),
          handler: ({ state, range, match }) => {
            const id = match[1];
            const task = tasks()(id);
            if (!task) return null;
            const start = range.from + match[0].indexOf(id);
            state.tr.replaceWith(start, start + id.length, state.schema.nodes.taskRef.create({ id, title: task.title ?? null }))
              .insertText(" ", start + 1);
          },
        }),
      ];
    },
  });

/** Fills a fresh Y.Doc's shared type from Markdown: the offline demo doc's starting text (MF-362). */
export function seedFromMarkdown(ydoc, markdown, ctx = {}) {
  prosemirrorToYXmlFragment(fromMarkdown(docSchema, markdown, ctx), ydoc.getXmlFragment(SHARED_TYPE));
  return ydoc;
}

/** A provider stand-in for demo mode: no socket, only the awareness the caret plugin reads. */
function localProvider(ydoc) {
  const awareness = new Awareness(ydoc);
  return { awareness, on() {}, off() {}, destroy() { awareness.destroy(); } };
}

/**
 * Mounts the editor on `el` for doc `docId`.
 * me: { login, name, avatar }; members(): [{login, name, avatar}]; tasks(): [{id, title}];
 * token: an app token sent as the socket's `maple-token` subprotocol (cookie auth when absent);
 * onEvent(name, data): status {status}, peers [{login,name,color,avatar}], synced, error {message}, openTask {id}.
 * demo: { markdown } opens a local-only doc seeded from Markdown, with no socket (the Mac app's signed-out mockup).
 * Planning visuals (MF-363): tasks() returns full tasks {id, title, state, pr, assignee, goal} for live
 * embeds; upload(file) → {path, name, mime, size} (default: POST /api/attachments); mermaidPage: the diagram page.
 * Comments (MF-364): threads() → DocThread[]; sendThreadCommand(cmd) relays doc.comment / doc.resolve /
 * doc.reopen to the server (no rail without it); call handle.threadsChanged() when threads() changes.
 * onEvent also gets threads {open} for badges.
 * Decisions (MF-367): decisions() → Decision[]; sendDecisionCommand(msg) relays decision.propose / edit /
 * accept / reject (no /decision without it); call handle.decisionsChanged() when decisions() changes.
 */
export function createDocEditor({ el, docId, me, members = () => [], tasks = () => [], threads = () => [], sendThreadCommand = null, decisions = () => [], sendDecisionCommand = null, upload = null, mermaidPage = "/app/mermaid/diagram.html", theme, token, origin = location.origin, onEvent = () => {}, demo = null }) {
  const ydoc = new Y.Doc();
  let provider;
  if (demo) {
    seedFromMarkdown(ydoc, demo.markdown ?? "", { members: members(), tasks: taskResolver(tasks()) });
    provider = localProvider(ydoc);
  } else {
    const ws = origin.replace(/^http/, "ws");
    provider = new WebsocketProvider(`${ws}/docs/${docId}`, "sync", ydoc, {
      protocols: token ? ["maple-token", token] : [],
      maxBackoffTime: 10_000,
    });
  }
  const user = { login: me.login, name: me.name || me.login, color: colorFor(me.login), avatar: me.avatar ?? null };
  const resolver = () => taskResolver(tasks());
  const ctx = () => ({ members: members(), tasks: resolver() });

  const shell = document.createElement("div");
  shell.className = "doc-editor-shell" + (sendThreadCommand ? " with-rail" : "");
  const root = document.createElement("div");
  root.className = "doc-editor";
  shell.append(root);
  el.append(shell);
  let rail = null;
  const bubble = document.createElement("div");

  const send = upload ?? (async (file) => {
    const res = await fetch(`${origin}/api/attachments?name=${encodeURIComponent(file.name || "pasted")}`, {
      method: "POST",
      body: file,
      credentials: "same-origin",
      headers: { "content-type": file.type || "application/octet-stream", ...(token ? { authorization: `Bearer ${token}` } : {}) },
    });
    if (!res.ok) throw new Error((await res.text()) || `upload failed (${res.status})`);
    return res.json();
  });
  // The node views' callbacks (nodes.js).
  const host = {
    tasks, members, docId, mermaidPage, origin, listeners: new Set(), decisions, me: me.login,
    onEvent: (name, data) => (name === "decision" ? sendDecisionCommand?.(data) : onEvent(name, data)),
  };
  /** Uploads files and inserts each as an image or file chip at `pos` (the selection when absent). */
  async function insertFiles(files, pos = null) {
    for (const file of files) {
      try {
        const node = nodeForUpload(await send(file));
        const at = pos ?? editor.state.selection.to;
        editor.chain().focus().insertContentAt(at, node).run();
      } catch (e) {
        onEvent("error", { message: `Couldn't upload ${file.name}: ${e.message}` });
      }
    }
  }
  const pick = (accept) => {
    const input = Object.assign(document.createElement("input"), { type: "file", accept, multiple: true });
    input.addEventListener("change", () => insertFiles([...input.files]));
    input.click();
  };

  const editor = new Editor({
    element: root,
    extensions: [
      ...schemaExtensions({
        mention: { suggestions: mentionSuggestions({ members, tasks }) },
        host,
      }),
      Extension.create({ name: "docVisuals", addStorage: () => ({ pick, embedNext: false, decide: sendDecisionCommand ? () => proposeDecision(editor, host) : null }) }),
      Collaboration.configure({ document: ydoc, field: SHARED_TYPE }),
      CollaborationCaret.configure({ provider, user }),
      // The empty doc's hint (MF-382): marks the first empty paragraph `is-editor-empty`; editor.css draws the text.
      Placeholder.configure({ placeholder: PLACEHOLDER }),
      SlashMenu,
      TaskRefTyping(resolver),
      Extension.create({ name: "docComments", addProseMirrorPlugins: () => [commentHighlights(() => ({ threads: sendThreadCommand ? threads() : [], active: rail?.active(), ydoc }))] }),
      BubbleMenu.configure({ element: bubble, shouldShow: ({ editor, from, to }) => (from !== to || editor.isActive("table")) && !editor.isActive("codeBlock") }),
      Extension.create({
        name: "markdownPaste",
        addProseMirrorPlugins: () => [
          new Plugin({
            props: {
              handlePaste(view, event) {
                const files = [...(event.clipboardData?.files ?? [])];
                if (files.length) { event.preventDefault(); insertFiles(files); return true; }
                const text = event.clipboardData?.getData("text/plain");
                if (!text || event.clipboardData.getData("text/html") && !looksPlain(event)) return false;
                const slice = markdownPasteSlice(view.state.schema, text, ctx());
                if (!slice) return false;
                view.dispatch(view.state.tr.replaceSelection(slice).scrollIntoView());
                return true;
              },
              handleDrop(view, event, _slice, moved) {
                const files = [...(event.dataTransfer?.files ?? [])];
                if (moved || !files.length) return false;
                event.preventDefault();
                const at = view.posAtCoords({ left: event.clientX, top: event.clientY });
                insertFiles(files, at ? at.pos : null);
                return true;
              },
              handleClickOn(_view, _pos, node, _np, event) {
                if (node.type.name !== "taskRef") return false;
                event.preventDefault();
                onEvent("openTask", { id: node.attrs.id });
                return true;
              },
            },
          }),
        ],
      }),
    ],
    editorProps: { attributes: { class: "doc-prose", spellcheck: "true" } },
  });
  if (sendThreadCommand) {
    rail = createCommentRail({ editor, ydoc, docId, threads, members, send: sendThreadCommand, onCount: (open) => onEvent("threads", { open }) });
    shell.append(rail.rail);
  }
  bubble.append(bubbleMenuElement(editor, rail ? () => rail.startThread() : null, rail ? () => rail.startThread(true) : null));

  const peers = () => {
    const out = new Map();
    for (const [id, state] of provider.awareness.getStates()) {
      if (id === ydoc.clientID || !state.user?.login) continue;
      out.set(state.user.login, state.user);
    }
    return [...out.values()];
  };
  provider.on("status", ({ status }) => onEvent("status", { status }));
  provider.on("sync", (synced) => {
    if (!synced) return;
    ensureStarterBlock(ydoc);
    onEvent("synced", {});
  });
  provider.on("connection-close", (e) => e && e.code !== 1000 && onEvent("error", { message: e.reason || `closed (${e.code})`, code: e.code }));
  provider.awareness.on("change", () => onEvent("peers", peers()));
  if (demo) queueMicrotask(() => { ensureStarterBlock(ydoc); onEvent("status", { status: "connected" }); onEvent("synced", {}); });

  const setTheme = (t) => { root.dataset.theme = t === "dark" ? "dark" : "light"; };
  if (theme) setTheme(theme);

  return {
    editor,
    provider,
    ydoc,
    exportMarkdown: () => toMarkdown(editor.state.doc, { tasks: resolver(), decisions: (id) => decisions().find((d) => d.id === id) }),
    /** The host's tasks changed (a feed update): task embeds redraw, the selection stays. */
    tasksChanged: () => host.listeners.forEach((f) => f()),
    /** The host's decisions changed (snapshot / decision.updated): decision cards redraw. */
    decisionsChanged: () => host.listeners.forEach((f) => f()),
    /** Scrolls to a decision's card and flashes it (a #/docs/<id>?decision=<id> link). False: not in the doc. */
    showDecision: (id) => {
      const card = root.querySelector(`[data-decision="${CSS.escape(id)}"]`);
      if (!card) return false;
      card.scrollIntoView({ block: "center" });
      flashDecision(card);
      return true;
    },
    /** The host's threads changed (doc.threads / doc.thread.updated): highlights and the rail redraw. */
    threadsChanged: () => rail?.refresh(),
    /** Comment on the current selection (the bubble menu's Comment). */
    startThread: () => rail?.startThread(),
    insertFiles,
    setTheme,
    setEditable: (on) => editor.setEditable(on),
    /** Puts the caret at the end of the doc (a just-created doc opens ready to type). */
    focus: () => editor.commands.focus("end"),
    peers,
    destroy() {
      editor.destroy();
      provider.destroy();
      ydoc.destroy();
      shell.remove();
    },
  };
}

// HTML copied alongside plain text from an editor or a code view: only Markdown-looking plain text from
// a source that isn't rich (VS Code, a terminal) goes through the parser.
function looksPlain(event) {
  const html = event.clipboardData.getData("text/html");
  return /vscode|<pre|white-space:\s*pre/i.test(html);
}
