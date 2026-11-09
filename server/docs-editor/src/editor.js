// The docs editor (MF-361, docs/planning-docs.md): TipTap over a Y.Doc whose shared XmlFragment
// `prosemirror` syncs with the doc's DocHub through a y-websocket provider on /docs/<id>/sync.
import { Editor, Extension, InputRule } from "@tiptap/core";
import Collaboration from "@tiptap/extension-collaboration";
import CollaborationCaret from "@tiptap/extension-collaboration-caret";
import BubbleMenu from "@tiptap/extension-bubble-menu";
import { Plugin } from "@tiptap/pm/state";
import { DOMSerializer } from "@tiptap/pm/model";
import * as Y from "yjs";
import { WebsocketProvider } from "y-websocket";
import { prosemirrorToYXmlFragment } from "@tiptap/y-tiptap";
import { Awareness } from "y-protocols/awareness";
import { schema as docSchema, schemaExtensions, TASK_ID } from "./schema.js";
import { markdownPasteSlice, toMarkdown, fromMarkdown, taskResolver } from "./markdown.js";
import { SlashMenu, mentionSuggestions, bubbleMenuElement } from "./menus.js";
import { nodeForUpload } from "./nodes.js";

export { toMarkdown, fromMarkdown, taskResolver, nodeForUpload };

export const SHARED_TYPE = "prosemirror";

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
 * Planning visuals (MF-363): tasks() returns full tasks {id, title, state, pr, assignee, goal, findings} for
 * live embeds and research blocks; goals(): [{id, name}]; docGoal: the doc's goal id; upload(file) → {path,
 * name, mime, size} (default: POST /api/attachments); mermaidPage: the diagram page. onEvent also gets
 * createResearch {question, goal, docId, pos}, answered by handle.setResearchTask(pos, id).
 */
export function createDocEditor({ el, docId, me, members = () => [], tasks = () => [], goals = () => [], docGoal = null, upload = null, mermaidPage = "/app/mermaid/diagram.html", theme, token, origin = location.origin, onEvent = () => {}, demo = null }) {
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

  const root = document.createElement("div");
  root.className = "doc-editor";
  el.append(root);
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
  // The node views' callbacks (nodes.js). parseMarkdown/serializeFragment render research answers.
  const host = {
    tasks, members, goals, docGoal: () => docGoal, docId, onEvent, mermaidPage, origin,
    listeners: new Set(),
    parseMarkdown: (text) => fromMarkdown(docSchema, text, ctx()),
    serializeFragment: (frag) => DOMSerializer.fromSchema(docSchema).serializeFragment(frag),
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
      Extension.create({ name: "docVisuals", addStorage: () => ({ pick, embedNext: false }) }),
      Collaboration.configure({ document: ydoc, field: SHARED_TYPE }),
      CollaborationCaret.configure({ provider, user }),
      SlashMenu,
      TaskRefTyping(resolver),
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
  bubble.append(bubbleMenuElement(editor));

  const peers = () => {
    const out = new Map();
    for (const [id, state] of provider.awareness.getStates()) {
      if (id === ydoc.clientID || !state.user?.login) continue;
      out.set(state.user.login, state.user);
    }
    return [...out.values()];
  };
  provider.on("status", ({ status }) => onEvent("status", { status }));
  provider.on("sync", (synced) => synced && onEvent("synced", {}));
  provider.on("connection-close", (e) => e && e.code !== 1000 && onEvent("error", { message: e.reason || `closed (${e.code})`, code: e.code }));
  provider.awareness.on("change", () => onEvent("peers", peers()));
  if (demo) queueMicrotask(() => { onEvent("status", { status: "connected" }); onEvent("synced", {}); });

  const setTheme = (t) => { root.dataset.theme = t === "dark" ? "dark" : "light"; };
  if (theme) setTheme(theme);

  return {
    editor,
    provider,
    ydoc,
    exportMarkdown: () => toMarkdown(editor.state.doc, { tasks: resolver() }),
    /** The host's tasks changed (a feed update): task embeds and research blocks redraw, the selection stays. */
    tasksChanged: () => host.listeners.forEach((f) => f()),
    /** Answers a research block's createResearch: the block at `pos` (or the first unsent one) gets task `id`. */
    setResearchTask(pos, id) {
      let at = null;
      const node = typeof pos === "number" ? editor.state.doc.nodeAt(pos) : null;
      if (node?.type.name === "research" && !node.attrs.task) at = pos;
      else editor.state.doc.descendants((n, p) => { if (at == null && n.type.name === "research" && !n.attrs.task && n.attrs.question) at = p; });
      if (at == null) return false;
      const n = editor.state.doc.nodeAt(at);
      editor.view.dispatch(editor.state.tr.setNodeMarkup(at, null, { ...n.attrs, task: id }));
      return true;
    },
    insertFiles,
    setTheme,
    setEditable: (on) => editor.setEditable(on),
    focus: () => editor.commands.focus(),
    peers,
    destroy() {
      editor.destroy();
      provider.destroy();
      ydoc.destroy();
      root.remove();
    },
  };
}

// HTML copied alongside plain text from an editor or a code view: only Markdown-looking plain text from
// a source that isn't rich (VS Code, a terminal) goes through the parser.
function looksPlain(event) {
  const html = event.clipboardData.getData("text/html");
  return /vscode|<pre|white-space:\s*pre/i.test(html);
}
