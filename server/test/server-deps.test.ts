// The Deploy-button factory (afomera/maple-factory) builds from a standalone copy of server/ (scripts/update.mjs),
// where npm installs only server/package.json's dependencies. Every bare import reachable from the Worker's entry
// (including files it pulls in from docs-editor/ and web/app/) must therefore be declared here, or wrangler fails
// with `Could not resolve "…"` at deploy time — the monorepo workspace hoisting hides it locally (MF-399).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, existsSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const serverDir = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const pkg = JSON.parse(readFileSync(join(serverDir, "package.json"), "utf8"));
const declared = new Set([...Object.keys(pkg.dependencies ?? {}), ...Object.keys(pkg.devDependencies ?? {})]);

// `import … from "x"`, `export … from "x"`, `import "x"`, `import("x")` — static string specifiers only.
const IMPORT_RE = /(?:^|[^\w$.])(?:import|export)\s*(?:[\w$*{}\s,]+?\s*from\s*)?\(?\s*["']([^"'`$]+)["']/gm;

function resolveRelative(from: string, spec: string): string | null {
  const base = resolve(dirname(from), spec);
  for (const candidate of [base, `${base}.ts`, `${base}.js`, join(base, "index.ts"), join(base, "index.js")]) {
    if (existsSync(candidate) && !candidate.endsWith("/") && /\.(ts|js|mjs)$/.test(candidate)) return candidate;
  }
  // TypeScript-style `./x.js` that points at `./x.ts`.
  const ts = base.replace(/\.js$/, ".ts");
  return existsSync(ts) ? ts : null;
}

function packageName(spec: string): string {
  const parts = spec.split("/");
  return spec.startsWith("@") ? parts.slice(0, 2).join("/") : parts[0];
}

function bareImports(entry: string): Map<string, string> {
  const seen = new Set<string>();
  const found = new Map<string, string>(); // package → first file importing it
  const queue = [entry];
  while (queue.length) {
    const file = queue.pop()!;
    if (seen.has(file)) continue;
    seen.add(file);
    const source = readFileSync(file, "utf8").replace(/\/\*[\s\S]*?\*\//g, "").replace(/^\s*\/\/.*$/gm, "");
    for (const [, spec] of source.matchAll(IMPORT_RE)) {
      if (spec.startsWith(".")) {
        const target = resolveRelative(file, spec);
        assert.ok(target, `${file}: can't resolve ${spec}`);
        queue.push(target);
      } else if (!/^(node|cloudflare):/.test(spec)) {
        const name = packageName(spec);
        if (!found.has(name)) found.set(name, file.slice(serverDir.length + 1));
      }
    }
  }
  return found;
}

test("every package the Worker imports is declared in server/package.json", () => {
  const imports = bareImports(join(serverDir, "src/index.ts"));
  // Sanity: the walk reaches docs-editor through doc-hub.ts → headless.js.
  for (const name of ["@tiptap/core", "markdown-it", "prosemirror-markdown", "lowlight", "highlight.js"]) {
    assert.ok(imports.has(name), `expected the walk to find ${name}`);
  }
  const missing = [...imports].filter(([name]) => !declared.has(name)).map(([name, file]) => `${name} (from ${file})`);
  assert.deepEqual(missing, [], `undeclared in server/package.json: ${missing.join(", ")}`);
});

test("packageName reduces subpaths to the package", () => {
  assert.equal(packageName("highlight.js/lib/core"), "highlight.js");
  assert.equal(packageName("@tiptap/pm/model"), "@tiptap/pm");
  assert.equal(packageName("yjs"), "yjs");
});
