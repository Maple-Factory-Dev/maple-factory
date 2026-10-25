// End-to-end against `wrangler dev` and a real runner enrolled to it:
//   node server/test/e2e-local.mjs http://localhost:8790 <machine>
// Opens a shell session, types into it through the relay, then ends one session by Kill and one by
// exiting, and checks the causes the server records.

const [base = "http://localhost:8790", machine = "e2e-mac"] = process.argv.slice(2);
const ws = base.replace(/^http/, "ws");
const { token } = await (await fetch(`${base}/dev/token`, { method: "POST" })).json();
const headers = { authorization: `Bearer ${token}` };

const feed = new WebSocket(`${ws}/client/connect`, { headers });
const inbox = [];
let waiter = null;
feed.onmessage = (e) => { inbox.push(JSON.parse(e.data)); waiter?.(); };
const next = async (match, what, ms = 15000) => {
  const deadline = Date.now() + ms;
  for (;;) {
    const i = inbox.findIndex(match);
    if (i >= 0) return inbox.splice(i, 1)[0];
    if (Date.now() > deadline) throw new Error(`timed out waiting for ${what}`);
    await new Promise((r) => { waiter = r; setTimeout(r, 250); });
  }
};
await new Promise((r) => (feed.onopen = r));
feed.send(JSON.stringify({ type: "subscribe" }));
const snap = await next((m) => m.type === "snapshot", "snapshot");
const m0 = snap.machines.find((m) => m.id === machine);
console.log(`snapshot: ${snap.me.login} in ${snap.org}; ${machine} online=${m0?.online}`);
if (!m0?.online) throw new Error("machine not online");

async function openShell() {
  const before = new Set(m0.sessions.map((s) => s.session.id));
  feed.send(JSON.stringify({ type: "session.open", machine, agent: "shell", cwd: "~", cols: 100, rows: 30 }));
  const up = await next((m) => m.type === "machine.updated" && m.machine.id === machine && m.machine.sessions.some((s) => !before.has(s.session.id)), "session.opened");
  const s = up.machine.sessions.find((s) => !before.has(s.session.id));
  before.add(s.session.id);
  m0.sessions = up.machine.sessions;
  return s.session.id;
}

async function terminal(id) {
  const term = new WebSocket(`${ws}/client/terminal?machine=${machine}&session=${id}&cols=100&rows=30`, { headers });
  term.binaryType = "arraybuffer";
  let screen = "";
  term.onmessage = (e) => { if (typeof e.data !== "string") screen += new TextDecoder().decode(e.data); };
  await new Promise((r) => (term.onopen = r));
  const until = async (needle, ms = 10000) => {
    const deadline = Date.now() + ms;
    while (!screen.includes(needle)) {
      if (Date.now() > deadline) throw new Error(`terminal never showed ${JSON.stringify(needle)}; got ${JSON.stringify(screen.slice(-300))}`);
      await new Promise((r) => setTimeout(r, 100));
    }
  };
  return { term, until, type: (s) => term.send(new TextEncoder().encode(s)) };
}

// 1. Type through the relay and see the output.
const a = await openShell();
console.log(`opened shell ${a}`);
const t = await terminal(a);
await new Promise((r) => setTimeout(r, 800));
t.type("echo maple-$((6*7))\r");
await t.until("maple-42");
console.log("relay: typed a command and saw its output");

// 2. Kill it: the cause is `killed`.
feed.send(JSON.stringify({ type: "session.kill", machine, id: a }));
const killed = await next((m) => m.type === "session.ended" && m.end.id === a, "kill end");
console.log(`ended by Kill → cause=${killed.end.cause}`);
t.term.close();

// 3. Exit with a status: the cause is `exited`, with the code and the last screen.
const b = await openShell();
const t2 = await terminal(b);
await new Promise((r) => setTimeout(r, 800));
t2.type("echo bye; exit 3\r");
const exited = await next((m) => m.type === "session.ended" && m.end.id === b, "exit end");
console.log(`exited → cause=${exited.end.cause} code=${exited.end.code} detail=${exited.end.detail}; last line: ${JSON.stringify(exited.end.lastOutput.at(-1) ?? "")}`);
t2.term.close();
feed.close();

const ok = killed.end.cause === "killed" && exited.end.cause === "exited" && exited.end.code === 3;
console.log(ok ? "PASS" : "FAIL");
process.exit(ok ? 0 : 1);
