import Foundation

struct FileNode: Identifiable {
    enum Kind { case folder, file, css, config, test, env, markdown }

    let name: String
    var kind: Kind = .file
    var status: String? = nil
    var children: [FileNode]? = nil
    var id: String { name + String(children?.count ?? -1) }
}

enum MockData {
    static let workspace = "atlas-platform"

    static let tree: [FileNode] = [
        FileNode(name: "src", kind: .folder, children: [
            FileNode(name: "app", kind: .folder, children: [
                FileNode(name: "layout.tsx"),
                FileNode(name: "page.tsx"),
                FileNode(name: "globals.css", kind: .css),
            ]),
            FileNode(name: "components", kind: .folder, children: [
                FileNode(name: "AppShell.tsx"),
                FileNode(name: "CodeEditor.tsx"),
            ]),
            FileNode(name: "lib", kind: .folder, children: [
                FileNode(name: "api.ts", status: "M"),
                FileNode(name: "utils.ts"),
            ]),
            FileNode(name: "hooks", kind: .folder, children: [
                FileNode(name: "useProject.ts", status: "M"),
            ]),
        ]),
        FileNode(name: "public", kind: .folder, children: []),
        FileNode(name: "tests", kind: .folder, children: [
            FileNode(name: "auth.test.ts", kind: .test),
        ]),
        FileNode(name: ".env.example", kind: .env),
        FileNode(name: "package.json", kind: .config),
        FileNode(name: "tsconfig.json", kind: .config),
        FileNode(name: "README.md", kind: .markdown),
    ]

    static let initiallyCollapsed: Set<String> = ["public"]

    static let tabs = ["AssistantPanel.tsx", "CodeEditor.tsx", "api.ts"]

    static let code: [String] = [
        #"import { useState } from "react";"#,
        #"import { Send, Sparkles } from "lucide-react";"#,
        "",
        "type AssistantMessage = {",
        "  id: string;",
        #"  role: "user" | "assistant";"#,
        "  content: string;",
        "};",
        "",
        "export function AssistantPanel() {",
        "  const [messages, setMessages] =",
        "    useState<AssistantMessage[]>([]);",
        "",
        "  const handleSend = (content: string) => {",
        "    if (!content.trim()) return;",
        "",
        "    setMessages((current) => [",
        "      ...current,",
        "      {",
        "        id: crypto.randomUUID(),",
        #"        role: "user","#,
        "        content,",
        "      },",
        "    ]);",
        "  };",
        "",
        "  return (",
        #"    <section className="assistant-panel">"#,
        #"      <header className="assistant-header">"#,
        "        <Sparkles size={16} />",
        "        <span>Code Assistant</span>",
        "      </header>",
        "",
        #"      <div className="assistant-messages">"#,
        "        {messages.map((message) => (",
        "          <article key={message.id}>",
        "            {message.content}",
        "          </article>",
        "        ))}",
        "      </div>",
        "    </section>",
        "  );",
        "}",
    ]

    /// 1-based line numbers, matching what the gutter shows.
    static let currentLine = 20
    static let cursorColumn = 18
    static let changedLines = 14...24
    static let diagnostics: [Int: (word: String, message: String)] = [
        2: ("Send", "'Send' is declared but never used"),
    ]
}
