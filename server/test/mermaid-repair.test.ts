// MF-375: the shared Mermaid viewer quotes labels that clash with Mermaid's syntax when a flowchart doesn't parse.
// The repair lives inline in assets/mermaid/diagram.html (the native apps inline that page), so the test pulls it out.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const html = readFileSync(new URL("../../assets/mermaid/diagram.html", import.meta.url), "utf8");
const block = /\/\* mf-repair:start \*\/([\s\S]*?)\/\* mf-repair:end \*\//.exec(html);
assert.ok(block, "diagram.html has an mf-repair block");
const repairMermaid = new Function(`${block[1]}\nreturn repairMermaid;`)() as (s: string) => { source: string; changed: boolean };

const BRIEF = `flowchart LR
  SRC[server/docs-editor/src] -->|esbuild: npm run build:docs| B[server/web/app/docs/editor.bundle.js]
  B -->|gen:check verifies| CI[CI]
  B --> APP[/app #/docs/id/]
  B --> EMB[/app/docs/embed.html]
  NATIVE[Mac/iOS WKWebView] -->|mapleDocs.load docId token| EMB
  APP -->|cookie| SYNC[/docs/id/sync]
  EMB -->|subprotocol maple-token| SYNC
  SYNC --> HUB[DocHub DO: Yjs + awareness]
  APP -->|doc.create rename archive| ORG[OrgHub feed]`;

const FLOW = "flowchart LR\n  plan[Planner] --> runner[Runner]\n  runner --> review[Review]";

test("the MF-375 brief diagram's path labels come back quoted", () => {
  const { source, changed } = repairMermaid(BRIEF);
  assert.equal(changed, true);
  const lines = source.split("\n");
  assert.equal(lines[3], '  B --> APP["/app #/docs/id/"]');
  assert.equal(lines[4], '  B --> EMB["/app/docs/embed.html"]');
  assert.equal(lines[6], '  APP -->|cookie| SYNC["/docs/id/sync"]');
  // Everything else is untouched.
  for (const n of [0, 1, 2, 5, 7, 8, 9]) assert.equal(lines[n], BRIEF.split("\n")[n]);
});

test("valid shapes, quoted labels and plain flowcharts are unchanged", () => {
  for (const src of [
    FLOW,
    "flowchart TD\n  A[/parallelogram/] --> B[\\trap/]",
    "flowchart TD\n  C((circle)) --> D{decision}",
    'flowchart TD\n  E["x (y) #z"] --> F(["stadium"])',
    "graph LR\n  G[[sub]] --> H[(db)] --> I([stadium]) --> J{{hex}} --> K>flag] --> L(((dbl)))",
    "flowchart LR\n  A -->|yes| B\n  A -- no --> C\n  classDef hot fill:#f00\n  style A fill:#0f0",
  ]) {
    const r = repairMermaid(src);
    assert.equal(r.changed, false, src);
    assert.equal(r.source, src);
  }
});

test("sequence diagrams and other types are never touched", () => {
  const seq = "sequenceDiagram\n  A->>B: GET /app/docs/[id]\n  B-->>A: 200 (ok)";
  assert.deepEqual(repairMermaid(seq), { source: seq, changed: false });
  const state = "stateDiagram-v2\n  [*] --> Planning";
  assert.deepEqual(repairMermaid(state), { source: state, changed: false });
});

test("special characters in round, rhombus and edge labels are quoted, keeping the shape", () => {
  const { source, changed } = repairMermaid('flowchart LR\n  A(run (twice)) -->|go (now)| D{is it "done"?}');
  assert.equal(changed, true);
  assert.equal(source.split("\n")[1], '  A("run (twice)") -->|"go (now)"| D{"is it #quot;done#quot;?"}');
});
