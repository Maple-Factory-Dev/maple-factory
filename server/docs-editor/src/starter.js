// The starter paragraph an empty doc gets (MF-382). Its own module so node tests can run it without a DOM.
import * as Y from "yjs";

/** The shared XmlFragment the editor binds to (editor.js's SHARED_TYPE). */
const SHARED_TYPE = "prosemirror";

/** Who wrote the starter paragraph: a local origin, so it isn't mistaken for a peer's edit. */
export const STARTER_ORIGIN = "maple-docs-starter";

/**
 * Gives an empty doc one empty paragraph (MF-382). A brand-new doc's fragment has no blocks; the editor still
 * draws a stand-in paragraph, but it lives only in the view until someone types. Writing a real one makes every
 * client (web, Mac, iOS) start from the same block. Run after the first sync, so a doc with content is never touched; two
 * clients opening a new doc at the same moment can leave two empty paragraphs, which does no harm.
 * Returns true when it added the paragraph.
 */
export function ensureStarterBlock(ydoc) {
  const fragment = ydoc.getXmlFragment(SHARED_TYPE);
  if (fragment.length > 0) return false;
  ydoc.transact(() => fragment.insert(0, [new Y.XmlElement("paragraph")]), STARTER_ORIGIN);
  return true;
}
