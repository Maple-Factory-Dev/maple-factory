// The docs editor (MF-361, docs/planning-docs.md): TipTap over a Y.Doc whose shared XmlFragment
// `prosemirror` syncs with the doc's DocHub through a y-websocket provider on /docs/<id>/sync.
import { Editor, Extension, InputRule } from "@tiptap/core";
import Collaboration from "@tiptap/extension-collaboration";
import CollaborationCaret from "@tiptap/extension-collaboration-caret";
import BubbleMenu from "@tiptap/extension-bubble-menu";
import { Plugin } from "@tiptap/pm/state";
import * as Y from "yjs";
import { WebsocketProvider } from "y-websocket";
import { schemaExtensions, TASK_ID } from "./schema.js";
import { markdownPasteSlice, toMarkdown, fromMarkdown, taskResolver } from "./markdown.js";
import { SlashMenu, mentionSuggestions, bubbleMenuElement } from "./menus.js";

export { toMarkdown, fromMarkdown, taskResolver };

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

/**
 * Mounts the editor on `el` for doc `docId`.
 * me: { login, name, avatar }; members(): [{login, name, avatar}]; tasks(): [{id, title}];
 * token: an app token sent as the socket's `maple-token` subprotocol (cookie auth when absent);
 * onEvent(name, data): status {status}, peers [{login,name,color,avatar}], synced, error {message}, openTask {id}.
 */
export function createDocEditor({ el, docId, me, members = () => [], tasks = () => [], theme, token, origin = location.origin, onEvent = () => {} }) {
  const ydoc = new Y.Doc();
  const ws = origin.replace(/^http/, "ws");
  const provider = new WebsocketProvider(`${ws}/docs/${docId}`, "sync", ydoc, {
    protocols: token ? ["maple-token", token] : [],
    maxBackoffTime: 10_000,
  });
  const user = { login: me.login, name: me.name || me.login, color: colorFor(me.login), avatar: me.avatar ?? null };
  const resolver = () => taskResolver(tasks());
  const ctx = () => ({ members: members(), tasks: resolver() });

  const root = document.createElement("div");
  root.className = "doc-editor";
  el.append(root);
  const bubble = document.createElement("div");

  const editor = new Editor({
    element: root,
    extensions: [
      ...schemaExtensions({
        mention: { suggestions: mentionSuggestions({ members, tasks }) },
      }),
      Collaboration.configure({ document: ydoc, field: SHARED_TYPE }),
      CollaborationCaret.configure({ provider, user }),
      SlashMenu,
      TaskRefTyping(resolver),
      BubbleMenu.configure({ element: bubble, shouldShow: ({ editor, from, to }) => from !== to && !editor.isActive("codeBlock") }),
      Extension.create({
        name: "markdownPaste",
        addProseMirrorPlugins: () => [
          new Plugin({
            props: {
              handlePaste(view, event) {
                const text = event.clipboardData?.getData("text/plain");
                if (!text || event.clipboardData.getData("text/html") && !looksPlain(event)) return false;
                const slice = markdownPasteSlice(view.state.schema, text, ctx());
                if (!slice) return false;
                view.dispatch(view.state.tr.replaceSelection(slice).scrollIntoView());
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

  const setTheme = (t) => { root.dataset.theme = t === "dark" ? "dark" : "light"; };
  if (theme) setTheme(theme);

  return {
    editor,
    provider,
    ydoc,
    exportMarkdown: () => toMarkdown(editor.state.doc),
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
