import Foundation

struct DiffLine: Equatable, Sendable {
    enum Kind: Sendable { case context, added, removed }

    let kind: Kind
    let text: String
    let old: Int?
    let new: Int?
}

struct DiffHunk: Identifiable {
    let id = UUID()
    let header: String
    /// The plan step (1-based) this hunk implements, so reviewers can read code against intent.
    let step: Int?
    let lines: [DiffLine]

    /// Builds a hunk from unified-diff text: each line prefixed with " ", "+" or "-".
    init(oldStart: Int, newStart: Int, context: String = "", step: Int?, _ body: String) {
        var old = oldStart, new = newStart
        var parsed: [DiffLine] = []
        for raw in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let prefix = raw.first ?? " "
            let text = String(raw.dropFirst())
            switch prefix {
            case "+":
                parsed.append(DiffLine(kind: .added, text: text, old: nil, new: new)); new += 1
            case "-":
                parsed.append(DiffLine(kind: .removed, text: text, old: old, new: nil)); old += 1
            default:
                parsed.append(DiffLine(kind: .context, text: text, old: old, new: new)); old += 1; new += 1
            }
        }
        let oldCount = parsed.filter { $0.kind != .added }.count
        let newCount = parsed.filter { $0.kind != .removed }.count
        self.header = "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@ \(context)"
        self.step = step
        self.lines = parsed
    }
}

struct DiffFile: Identifiable {
    let path: String
    let added: Int
    let removed: Int
    var step: Int? = nil
    var hunks: [DiffHunk] = []
    /// Still being written by a building agent.
    var inProgress = false
    var id: String { path }
}

extension FactoryData {
    static func diff(for taskID: String) -> [DiffFile] {
        switch taskID {
        case "ATL-141": jose
        case "ATL-144": middleware
        default: []
        }
    }

    private static let jose: [DiffFile] = [
        DiffFile(path: "lib/auth/jwt.ts", added: 38, removed: 52, step: 1, hunks: [
            DiffHunk(oldStart: 1, newStart: 1, step: 1, """
            -import jwt from "jsonwebtoken";
            +import { SignJWT, jwtVerify } from "jose";
             import { env } from "@/lib/env";

            -const secret = env.AUTH_SECRET;
            +const secret = new TextEncoder().encode(env.AUTH_SECRET);

             export type TokenClaims = { sub: string; role: Role };
            """),
            DiffHunk(oldStart: 14, newStart: 13, context: "export type TokenClaims", step: 1, """
            -export function signAccessToken(claims: TokenClaims) {
            -  return jwt.sign(claims, secret, { expiresIn: "15m" });
            +export async function signAccessToken(claims: TokenClaims) {
            +  return new SignJWT(claims)
            +    .setProtectedHeader({ alg: "HS256" })
            +    .setExpirationTime("15m")
            +    .sign(secret);
             }

            -export function verifyAccessToken(token: string) {
            -  return jwt.verify(token, secret) as TokenClaims;
            +export async function verifyAccessToken(token: string) {
            +  const { payload } = await jwtVerify(token, secret);
            +  return payload as TokenClaims;
             }
            """),
        ]),
        DiffFile(path: "app/api/auth/refresh/route.ts", added: 12, removed: 9, step: 2, hunks: [
            DiffHunk(oldStart: 8, newStart: 8, context: "export async function POST(req: Request) {", step: 2, """
               const session = await getSession(req);
               if (!session) return unauthorized();

            -  const token = signAccessToken({ sub: session.userId, role: session.role });
            +  const token = await signAccessToken({ sub: session.userId, role: session.role });
               return Response.json({ token });
             }
            """),
        ]),
        DiffFile(path: "lib/auth/session.ts", added: 9, removed: 7, step: 2),
        DiffFile(path: "app/api/auth/login/route.ts", added: 6, removed: 5, step: 2),
        DiffFile(path: "middleware.ts", added: 4, removed: 3, step: 2),
        DiffFile(path: "package.json", added: 1, removed: 1, step: 3, hunks: [
            DiffHunk(oldStart: 21, newStart: 21, context: "\"dependencies\": {", step: 3, """
                 "drizzle-orm": "^0.36.0",
            -    "jsonwebtoken": "^9.0.2",
            +    "jose": "^5.9.6",
                 "next": "15.0.3",
            """),
        ]),
        DiffFile(path: "package-lock.json", added: 18, removed: 41, step: 3),
        DiffFile(path: "tests/auth/jwt.test.ts", added: 60, removed: 4, step: 4),
        DiffFile(path: "tests/auth/refresh.test.ts", added: 22, removed: 6, step: 4),
    ]

    private static let middleware: [DiffFile] = [
        DiffFile(path: "lib/auth/middleware.ts", added: 64, removed: 0, step: 2, hunks: [
            DiffHunk(oldStart: 0, newStart: 1, step: 2, """
            +import { getSession, type Session } from "@/lib/auth/session";
            +import { unauthorized, forbidden } from "@/lib/http";
            +
            +type Handler = (req: Request, session: Session) => Promise<Response>;
            +
            +export function withAuth(handler: Handler, options: { role?: Role } = {}) {
            +  return async (req: Request) => {
            +    const session = await getSession(req);
            +    if (!session) return unauthorized();
            +    if (options.role && session.role !== options.role) return forbidden();
            +    return handler(req, session);
            +  };
            +}
            """),
        ]),
        DiffFile(path: "app/api/projects/route.ts", added: 8, removed: 14, step: 3),
        DiffFile(path: "app/api/projects/[id]/route.ts", added: 9, removed: 17, step: 3),
        DiffFile(path: "app/api/billing/invoices/route.ts", added: 4, removed: 9, step: 4, hunks: [
            DiffHunk(oldStart: 1, newStart: 1, step: 4, """
            -import { requireSession } from "@/lib/auth/legacy";
            +import { withAuth } from "@/lib/auth/middleware";

            -export async function GET(req: Request) {
            -  const session = await requireSession(req);
            -  if (session.role !== "admin") return forbidden();
            +export const GET = withAuth(async (req, session) => {
               const invoices = await listInvoices(session.orgId);
               return Response.json(invoices);
            -}
            +}, { role: "admin" });
            """),
        ], inProgress: true),
    ]

    /// The mockup's review threads on a task's pull request.
    static func reviewThreads(for taskID: String) -> [Wire.ReviewThread] {
        guard taskID == "ATL-141" else { return [] }
        let hour: UInt64 = 3_600_000
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        return [
            Wire.ReviewThread(id: "PRRT_1", path: "lib/auth/jwt.ts", line: 21, startLine: 20, side: .new, resolved: false, outdated: false, comments: [
                .init(author: "ana-k", body: "Pin the algorithm here too: `jwtVerify(token, secret, { algorithms: [\"HS256\"] })`, or a token signed with another alg could slip through.", at: now - 3 * hour),
                .init(author: "dmitri", body: "+1, jose accepts whatever the header says otherwise.", at: now - 2 * hour),
            ]),
            Wire.ReviewThread(id: "PRRT_2", path: "package.json", line: 22, side: .new, resolved: true, outdated: false, comments: [
                .init(author: "dmitri", body: "Is jose 5 fine on the edge runtime?", at: now - 5 * hour),
                .init(author: "ana-k", body: "Yes, it's what Vercel recommends.", at: now - 4 * hour),
            ]),
        ]
    }

    /// Stand-in for fetching a collapsed file's diff from the PR.
    static func loadHunks(for file: DiffFile) -> [DiffHunk] {
        let name = (file.path as NSString).lastPathComponent
        let step = file.step

        if name.hasSuffix(".test.ts") {
            return [DiffHunk(oldStart: 1, newStart: 1, step: step, """
             import { signAccessToken, verifyAccessToken } from "@/lib/auth/jwt";
            +import { decodeProtectedHeader } from "jose";
             
             describe("access tokens", () => {
            -  it("round-trips claims", () => {
            -    const token = signAccessToken({ sub: "u_1", role: "member" });
            -    expect(verifyAccessToken(token).sub).toBe("u_1");
            +  it("round-trips claims", async () => {
            +    const token = await signAccessToken({ sub: "u_1", role: "member" });
            +    expect((await verifyAccessToken(token)).sub).toBe("u_1");
            +  });
            +
            +  it("signs with HS256", async () => {
            +    const token = await signAccessToken({ sub: "u_1", role: "member" });
            +    expect(decodeProtectedHeader(token).alg).toBe("HS256");
               });
            """)]
        }
        if name == "package-lock.json" {
            return [DiffHunk(oldStart: 4120, newStart: 4120, context: "\"packages\": {", step: step, """
            -    "node_modules/jsonwebtoken": {
            -      "version": "9.0.2",
            -      "resolved": "https://registry.npmjs.org/jsonwebtoken/-/jsonwebtoken-9.0.2.tgz",
            +    "node_modules/jose": {
            +      "version": "5.9.6",
            +      "resolved": "https://registry.npmjs.org/jose/-/jose-5.9.6.tgz",
                   "license": "MIT",
            """)]
        }
        if file.path.hasPrefix("app/api") || name == "middleware.ts" || name == "session.ts" {
            return [DiffHunk(oldStart: 12, newStart: 12, step: step, """
               const session = await getSession(req);
            -  const claims = verifyAccessToken(bearer(req));
            +  const claims = await verifyAccessToken(bearer(req));
               if (claims.sub !== session?.userId) return unauthorized();
            """)]
        }
        return [DiffHunk(oldStart: 1, newStart: 1, step: step, """
        -// TODO: migrate
        +// Migrated by \(file.path)
        """)]
    }
}

extension DiffFile {
    /// The files in a unified diff (`git diff` output), with their hunks.
    static func parse(_ patch: String) -> [DiffFile] {
        var files: [DiffFile] = []
        var path: String?
        var added = 0, removed = 0
        var hunks: [DiffHunk] = []
        var hunk: (old: Int, new: Int, context: String, lines: [String])?

        func closeHunk() {
            if let h = hunk { hunks.append(DiffHunk(oldStart: h.old, newStart: h.new, context: h.context, step: nil, h.lines.joined(separator: "\n"))) }
            hunk = nil
        }
        func closeFile() {
            closeHunk()
            if let path { files.append(DiffFile(path: path, added: added, removed: removed, hunks: hunks)) }
            path = nil
            added = 0
            removed = 0
            hunks = []
        }

        for line in patch.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("diff --git ") {
                closeFile()
                // "diff --git a/x b/x": the b side, until +++ says better.
                path = line.components(separatedBy: " b/").last
            } else if hunk == nil, line.hasPrefix("+++ ") {
                if line != "+++ /dev/null" { path = String(line.dropFirst(4)).replacingOccurrences(of: "b/", with: "", options: .anchored) }
            } else if hunk == nil, line.hasPrefix("--- ") || line.hasPrefix("index ") || line.hasPrefix("new file") || line.hasPrefix("deleted file") || line.hasPrefix("Binary files") {
                continue
            } else if line.hasPrefix("@@") {
                closeHunk()
                // @@ -12,7 +12,9 @@ context
                let parts = line.split(separator: " ", maxSplits: 4)
                let start = { (s: Substring) in Int(s.dropFirst().split(separator: ",").first ?? "") ?? 1 }
                let context = line.components(separatedBy: "@@").dropFirst(2).joined(separator: "@@").trimmingCharacters(in: .whitespaces)
                hunk = (parts.count > 1 ? start(parts[1]) : 1, parts.count > 2 ? start(parts[2]) : 1, context, [])
            } else if hunk != nil, let first = line.first, "+- ".contains(first) {
                if first == "+" { added += 1 } else if first == "-" { removed += 1 }
                hunk?.lines.append(line)
            }
        }
        closeFile()
        return files
    }
}
