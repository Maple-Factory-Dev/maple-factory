import Foundation

struct DiffLine {
    enum Kind { case context, added, removed }

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
