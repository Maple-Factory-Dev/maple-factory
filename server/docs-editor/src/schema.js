// The editor's document schema, as TipTap extensions (docs/planning-docs.md). Shared by the browser editor
// and the Markdown tests, so both see the same node and mark names.
import { getSchema, Node, mergeAttributes } from "@tiptap/core";
import StarterKit from "@tiptap/starter-kit";
import { TaskList, TaskItem } from "@tiptap/extension-list";
import Mention from "@tiptap/extension-mention";
import { visualExtensions } from "./nodes.js";
import { DocCodeBlock } from "./codeblock.js";

/** `MF-12`, the shape of a task id. */
export const TASK_ID = /[A-Z][A-Z0-9]{0,9}-\d{1,6}/;

/** A task reference: an inline atom that shows the id (and its title on hover) and links to #/t/<id>. */
export const TaskRef = Node.create({
  name: "taskRef",
  group: "inline",
  inline: true,
  atom: true,
  selectable: true,
  addAttributes() {
    return {
      id: { default: null, parseHTML: (el) => el.getAttribute("data-task") },
      title: { default: null, parseHTML: (el) => el.getAttribute("title") },
    };
  },
  parseHTML() {
    return [{ tag: "a[data-task]" }];
  },
  renderHTML({ node, HTMLAttributes }) {
    return [
      "a",
      mergeAttributes(HTMLAttributes, {
        "data-task": node.attrs.id,
        href: `#/t/${node.attrs.id}`,
        class: "doc-taskref",
        title: node.attrs.title ?? node.attrs.id,
      }),
      node.attrs.id,
    ];
  },
  renderText({ node }) {
    return node.attrs.id;
  },
});

/** The extensions that make up the schema. `mention`/`taskRef` configure the browser-only parts (suggestion
 *  menus); `host` carries the planning-visual node views' callbacks (MF-363, see nodes.js). The divider is
 *  StarterKit's horizontalRule. */
export function schemaExtensions({ mention = {}, taskRef = {}, host = null } = {}) {
  return [
    // Undo/redo comes from the Collaboration extension (y-prosemirror's), not ProseMirror history.
    StarterKit.configure({ undoRedo: false, codeBlock: false, link: { openOnClick: false, autolink: true } }),
    // Fenced code with highlighting and a language picker (MF-384); still the `codeBlock` node.
    DocCodeBlock,
    TaskList,
    TaskItem.configure({ nested: true }),
    Mention.configure({
      HTMLAttributes: { class: "doc-mention" },
      renderText: ({ node }) => `@${node.attrs.id}`,
      renderHTML: ({ node, options }) => ["span", mergeAttributes({ "data-type": "mention", "data-id": node.attrs.id }, options.HTMLAttributes), `@${node.attrs.label ?? node.attrs.id}`],
      ...mention,
    }),
    TaskRef.extend(taskRef),
    ...visualExtensions(host),
  ];
}

export const schema = getSchema(schemaExtensions());
