// Markdown for comments, change requests and briefs: the same subset the Mac app's MarkdownPreview
// reads (headings, lists, task lists, quotes, fenced code with a language, inline code, bold, italic,
// links), with the same small syntax highlighter for code.
//
// parse() is pure and returns a tree; render() builds DOM from it through the app's h(), so every
// string goes in as text. Nothing is ever set as HTML, and links open only for http(s) and mailto.

// ---- blocks ----

export function parse(source) {
  const blocks = [];
  let paragraph = [];
  let fence = null;

  const flush = () => {
    if (paragraph.length) blocks.push({ type: "paragraph", inline: inline(paragraph.join(" ")) });
    paragraph = [];
  };
  // Runs of list lines of the same kind become one list.
  const listItem = (ordered, start, item) => {
    flush();
    const last = blocks.at(-1);
    if (last?.type === "list" && last.ordered === ordered) last.items.push(item);
    else blocks.push({ type: "list", ordered, start, items: [item] });
  };

  for (const raw of String(source ?? "").replace(/\r\n?/g, "\n").split("\n")) {
    const line = raw.trim();
    const indent = raw.length - raw.trimStart().length;

    if (fence) {
      // Only a bare run of backticks closes the block; "```ts" inside it is code.
      if (/^```+$/.test(line)) {
        blocks.push({ type: "code", lang: fence.lang, text: fence.lines.join("\n") });
        fence = null;
      } else {
        // An indented fence (under a list item, say) indents its lines the same amount.
        fence.lines.push(raw.slice(Math.min(fence.indent, raw.length - raw.trimStart().length)));
      }
      continue;
    }
    if (line.startsWith("```")) {
      flush();
      const tag = line.slice(3).split(/[\s{,]/)[0].toLowerCase();
      fence = { indent, lang: tag || null, lines: [] };
      continue;
    }

    if (!line) { flush(); continue; }
    if (line === "---") { flush(); blocks.push({ type: "rule" }); continue; }

    let m;
    if ((m = /^(#{1,6}) (.*)$/.exec(line))) {
      flush();
      blocks.push({ type: "heading", level: m[1].length, inline: inline(m[2].trim()) });
    } else if ((m = /^[-*] \[([ xX])\] (.*)$/.exec(line))) {
      listItem(false, 1, { checked: m[1] !== " ", inline: inline(m[2]) });
    } else if ((m = /^[-*] (.*)$/.exec(line))) {
      listItem(false, 1, { checked: null, inline: inline(m[1]) });
    } else if ((m = /^(\d+)\. (.*)$/.exec(line))) {
      listItem(true, Number(m[1]), { checked: null, inline: inline(m[2]) });
    } else if ((m = /^> ?(.*)$/.exec(line))) {
      flush();
      blocks.push({ type: "quote", inline: inline(m[1]) });
    } else {
      paragraph.push(line);
    }
  }
  if (fence) blocks.push({ type: "code", lang: fence.lang, text: fence.lines.join("\n") });
  flush();
  return blocks;
}

// ---- inline ----

const SAFE_LINK = /^(https?:|mailto:)/i;

export function inline(text) {
  const out = [];
  let plain = "";
  const push = (node) => {
    if (plain) out.push({ type: "text", text: plain });
    plain = "";
    out.push(node);
  };
  const wordBefore = (i) => i > 0 && /[\w]/.test(text[i - 1]);

  for (let i = 0; i < text.length; ) {
    const c = text[i];
    const rest = text.slice(i);
    let m;

    if (c === "\\" && i + 1 < text.length && /[\\`*_[\]()#>@-]/.test(text[i + 1])) {
      plain += text[i + 1];
      i += 2;
    } else if (c === "`" && (m = /^(`+)([\s\S]+?)\1(?!`)/.exec(rest))) {
      push({ type: "code", text: m[2] });
      i += m[0].length;
    } else if ((m = /^(\*\*|__)(?=\S)([\s\S]+?)(?<=\S)\1/.exec(rest)) && !(c === "_" && wordBefore(i))) {
      push({ type: "strong", children: inline(m[2]) });
      i += m[0].length;
    } else if ((m = /^([*_])(?=\S)([\s\S]+?)(?<=\S)\1/.exec(rest)) && !(c === "_" && wordBefore(i))) {
      push({ type: "em", children: inline(m[2]) });
      i += m[0].length;
    } else if (c === "[" && (m = /^\[([^\]]*)\]\(([^)\s]*)\)/.exec(rest))) {
      const children = inline(m[1]);
      if (SAFE_LINK.test(m[2])) push({ type: "link", href: m[2], children });
      else for (const child of children) push(child);
      i += m[0].length;
    } else if (!wordBefore(i) && (m = /^https?:\/\/[^\s<>()]+[^\s<>().,;:!?'"]/.exec(rest))) {
      push({ type: "link", href: m[0], children: [{ type: "text", text: m[0] }] });
      i += m[0].length;
    } else if (c === "@" && !wordBefore(i) && (m = /^@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?/.exec(rest))) {
      push({ type: "mention", text: m[0] });
      i += m[0].length;
    } else {
      plain += c;
      i += 1;
    }
  }
  if (plain) out.push({ type: "text", text: plain });
  return out;
}

// ---- code ----

const words = (s) => new Set(s.split(" "));
const GRAMMARS = {
  swift: {
    keywords: words("actor as async await break case catch class continue default defer do else enum extension false fileprivate for func guard if import in init inout internal is let nil private protocol public repeat return self Self some any static struct super switch throw throws true try typealias var where while"),
    line: ["//"], block: ["/*", "*/"], quotes: '"', types: true,
  },
  ts: {
    keywords: words("as async await break case catch class const continue default delete do else enum export extends false finally for from function if implements import in instanceof interface let new null of private public readonly return static super switch this throw true try type typeof undefined var void while yield"),
    line: ["//"], block: ["/*", "*/"], quotes: "\"'`", types: true,
  },
  json: { keywords: words("true false null"), line: [], quotes: '"' },
  sh: {
    keywords: words("if then else elif fi for while do done case esac in function return export local echo cd set unset exit source"),
    line: ["#"], quotes: "\"'",
  },
  ruby: {
    keywords: words("alias and begin break case class def do else elsif end ensure false for if in module next nil not or redo rescue retry return self super then true undef unless until when while yield require attr_reader attr_accessor"),
    line: ["#"], quotes: "\"'", types: true,
  },
  python: {
    keywords: words("and as assert async await break class continue def del elif else except False finally for from global if import in is lambda None nonlocal not or pass raise return True try while with yield self"),
    line: ["#"], quotes: "\"'",
  },
  go: {
    keywords: words("break case chan const continue default defer else fallthrough false for func go goto if import interface map nil package range return select struct switch true type var"),
    line: ["//"], block: ["/*", "*/"], quotes: "\"'`", types: true,
  },
};
const ALIASES = {
  typescript: "ts", tsx: "ts", js: "ts", javascript: "ts", jsx: "ts", mjs: "ts", cjs: "ts",
  jsonc: "json", bash: "sh", shell: "sh", zsh: "sh", console: "sh", rb: "ruby", py: "python", golang: "go",
};

/** Splits code into [{ text, token }], token one of plain, keyword, string, number, comment, type,
 *  added, removed, meta. Unknown languages come back as one plain token. */
export function highlight(code, lang) {
  code = String(code ?? "");
  lang = String(lang ?? "").toLowerCase();
  if (lang === "diff" || lang === "patch") return diff(code);
  const g = GRAMMARS[ALIASES[lang] ?? lang];
  if (!g) return code ? [{ text: code, token: "plain" }] : [];

  const out = [];
  const emit = (text, token) => {
    const last = out.at(-1);
    if (last?.token === token) last.text += text;
    else out.push({ text, token });
  };
  const ident = (c) => c !== undefined && /[\p{L}\p{N}_$]/u.test(c);

  for (let i = 0; i < code.length; ) {
    const c = code[i];
    let j;
    if (g.line.some((p) => code.startsWith(p, i))) {
      j = code.indexOf("\n", i);
      if (j < 0) j = code.length;
      emit(code.slice(i, j), "comment");
    } else if (g.block && code.startsWith(g.block[0], i)) {
      j = code.indexOf(g.block[1], i + g.block[0].length);
      j = j < 0 ? code.length : j + g.block[1].length;
      emit(code.slice(i, j), "comment");
    } else if (g.quotes.includes(c)) {
      // Strings end at their closing quote or the end of the line, skipping escapes.
      j = i + 1;
      while (j < code.length && code[j] !== c && (c === "`" || code[j] !== "\n")) j += code[j] === "\\" ? 2 : 1;
      j = Math.min(j + 1, code.length);
      emit(code.slice(i, j), "string");
    } else if (/\p{N}/u.test(c) && !ident(code[i - 1])) {
      j = i + 1;
      while (j < code.length && (/[\p{L}\p{N}_]/u.test(code[j]) || (code[j] === "." && /\p{N}/u.test(code[j + 1] ?? "")))) j++;
      emit(code.slice(i, j), "number");
    } else if (ident(c)) {
      j = i + 1;
      while (ident(code[j])) j++;
      const word = code.slice(i, j);
      emit(word, g.keywords.has(word) ? "keyword" : g.types && /^\p{Lu}/u.test(word) ? "type" : "plain");
    } else {
      j = i + 1;
      emit(c, "plain");
    }
    i = j;
  }
  return out;
}

function diff(code) {
  return code.split("\n").map((line, i) => ({
    text: (i ? "\n" : "") + line,
    token: /^(\+\+\+|---|@@)/.test(line) ? "meta" : line.startsWith("+") ? "added" : line.startsWith("-") ? "removed" : "plain",
  }));
}

// ---- DOM ----

/** Builds the tree as DOM with the app's h(tag, attrs, ...children); strings become text nodes. */
export function render(blocks, h) {
  const spans = (nodes) => nodes.map((n) => {
    switch (n.type) {
      case "code": return h("code", {}, n.text);
      case "strong": return h("strong", {}, spans(n.children));
      case "em": return h("em", {}, spans(n.children));
      case "link": return h("a", { href: n.href, target: "_blank", rel: "noopener noreferrer" }, spans(n.children));
      case "mention": return h("span", { class: "mention" }, n.text);
      default: return n.text;
    }
  });

  return h("div", { class: "md" }, blocks.map((b) => {
    switch (b.type) {
      case "heading": return h(`h${Math.min(b.level + 2, 6)}`, { class: "md-h" }, spans(b.inline));
      case "list":
        return h(b.ordered ? "ol" : "ul", { start: b.ordered && b.start !== 1 ? String(b.start) : null, class: b.items.some((i) => i.checked != null) ? "tasks" : null },
          b.items.map((item) => h("li", {},
            item.checked != null && h("input", { type: "checkbox", checked: item.checked, disabled: true }),
            spans(item.inline))));
      case "quote": return h("blockquote", {}, spans(b.inline));
      case "code":
        return h("div", { class: "md-code" },
          b.lang && h("span", { class: "md-lang" }, b.lang),
          h("pre", {}, h("code", {}, highlight(b.text, b.lang).map((t) => t.token === "plain" ? t.text : h("span", { class: `tok-${t.token}` }, t.text)))));
      case "rule": return h("hr", {});
      default: return h("p", {}, spans(b.inline));
    }
  }));
}

export const markdown = (source, h) => render(parse(source), h);
