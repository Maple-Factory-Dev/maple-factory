import Foundation

extension FactoryData {
    static func diff(for taskID: String) -> [DiffFile] {
        switch taskID {
        case "ATL-141": jose
        case "ATL-144": middleware
        default: []
        }
    }

    /// The mockup's commits on a task's branch, oldest first: ATL-141's, a commit per stretch of its plan.
    static func commits(for taskID: String) -> [DiffCommit] {
        guard taskID == "ATL-141" else { return [] }
        let now = Date()
        return joseCommits.enumerated().map { index, commit in
            let files = jose.filter { commit.steps.contains($0.step ?? 0) }
            return DiffCommit(
                sha: commit.sha, subject: commit.subject, body: commit.body, author: "Maple-2", at: now.addingTimeInterval(Double(index - joseCommits.count) * 1500),
                added: files.map(\.added).reduce(0, +), removed: files.map(\.removed).reduce(0, +), fileCount: files.count
            )
        }
    }

    /// The files one of the mockup's commits changes.
    static func diff(for taskID: String, commit sha: String) -> [DiffFile] {
        guard taskID == "ATL-141", let commit = joseCommits.first(where: { $0.sha == sha }) else { return [] }
        return jose.filter { commit.steps.contains($0.step ?? 0) }
    }

    private static let joseCommits: [(sha: String, subject: String, body: String?, steps: Set<Int>)] = [
        ("3f9c2a1d7e4b8c06a5f1d2e3b4c5a6978e0d1f2a", "Sign and verify tokens with jose", "jose's SignJWT and jwtVerify are async and take the secret as bytes, so the helpers are async now too.", [1]),
        ("8b41e07c2d9a5f3e1c6b8a7d4e2f0c9b1a3d5e7f", "Await the async token helpers at every call site", "The refresh, login and session routes and the middleware each called them synchronously.", [2]),
        ("c27d5e9a1b3f8e0d6c4a2b9e7f1d3c5a8b0e2d4f", "Swap jsonwebtoken for jose and update the auth tests", nil, [3, 4]),
    ]

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
        generatedRoutes,
    ]

    /// A generated file of about 5,000 lines, so a long diff can be scrolled and filmed in demo mode.
    private static let generatedRoutes: DiffFile = {
        var body: [String] = []
        var added = 0, removed = 0
        for route in 0..<540 {
            let name = "route\(route)"
            body.append(" export const \(name) = {")
            if route % 3 == 0 {
                body.append("-  path: \"/api/v1/\(name)\",")
                removed += 1
            }
            body.append("+  path: \"/api/v2/\(name)\",")
            body.append("+  method: \"\(["GET", "POST", "PUT", "DELETE"][route % 4])\",")
            body.append("+  auth: withAuth({ role: \"\(route % 5 == 0 ? "admin" : "member")\" }),")
            body.append("+  handler: async (req: Request) => handle\(route)(req),")
            body.append("+  timeout: \(1000 + route * 10),")
            added += 5
            body.append("   cache: false,")
            body.append(" };")
            body.append(" ")
        }
        let hunk = DiffHunk(oldStart: 1, newStart: 1, context: "// Generated by routegen", step: 3, body.joined(separator: "\n"))
        return DiffFile(path: "lib/generated/routes.ts", added: added, removed: removed, step: 3, hunks: [hunk])
    }()

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
