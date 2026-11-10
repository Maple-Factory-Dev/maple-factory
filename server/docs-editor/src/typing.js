// Editor input rules and guards that node tests can run without a DOM (MF-376).
import { Extension, InputRule } from "@tiptap/core";
import { Plugin, PluginKey, TextSelection } from "@tiptap/pm/state";
import { ySyncPluginKey } from "@tiptap/y-tiptap";
import { TASK_ID } from "./schema.js";

/** `MF-12 ` (an id, then the space that ends it). */
export const TASK_REF_TYPED = new RegExp(`(?:^|\\s)(${TASK_ID.source})\\s$`);

/**
 * The input rule's handler. TipTap has already put the typed space in the doc when it runs (range.to is past
 * it), so the id and that space become the task ref and exactly one space, with the caret after it.
 */
export function taskRefTyped({ state, range, match }, resolve) {
  const id = match[1];
  const task = resolve(id);
  if (!task) return null;
  const start = range.from + match[0].indexOf(id);
  const { tr, schema } = state;
  tr.replaceWith(start, range.to, [schema.nodes.taskRef.create({ id, title: task.title ?? null }), schema.text(" ")]);
  tr.setSelection(TextSelection.create(tr.doc, start + 2));
}

/** Typing `MF-12 ` (a task the resolver knows) turns the id into a live task ref. */
export const TaskRefTyping = (tasks) =>
  Extension.create({
    name: "taskRefTyping",
    addInputRules: () => [new InputRule({ find: TASK_REF_TYPED, handler: (props) => taskRefTyped(props, tasks()) })],
  });

export const syncHoldKey = new PluginKey("mapleSyncHold");

/**
 * Drops local edits until the provider's first sync (MF-376). Before it, the editor shows only a stand-in paragraph
 * over an empty Y.Doc; text typed there was merged badly with the server's state when it arrived (slash-menu text
 * left behind, blocks split or retyped as headings). The server's own update (y-sync's meta) always goes through,
 * as do selection changes. After the first sync, a reconnect never holds edits: y-websocket buffers them.
 */
export function syncHold(isSynced) {
  return new Plugin({
    key: syncHoldKey,
    filterTransaction: (tr) => !tr.docChanged || isSynced() || tr.getMeta(ySyncPluginKey) !== undefined,
  });
}
