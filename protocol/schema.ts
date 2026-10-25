// The wire protocol between runners, the server and the apps: the single source of truth.
// `npm run gen` writes the Rust, TypeScript and Swift types from it; `npm run gen:check` fails when
// a generated file is stale.
//
// Field types: string, bool, u16, u32, u64, i32, f64, uuid, json, a type's name, `T?` (optional),
// `T[]` (list) and `map<T>` (string keys). JSON field names are camelCase in every language.
//
// Text frames carry these messages as JSON, tagged by `type`. Binary frames carry terminal bytes,
// `[16-byte session uuid][payload]`: output runner → server → app, input the other way.

export type Fields = Record<string, string>;
export type Doc = { doc?: string };
export type Struct = Doc & { fields: Fields; fieldDocs?: Record<string, string> };
export type Enum = Doc & { values: Record<string, string> };
export type Variant = Doc & { fields?: Fields; fieldDocs?: Record<string, string> };
export type Union = Doc & { variants: Record<string, Variant> };

export const version = 1;

export const enums: Record<string, Enum> = {
  EndCause: {
    doc: "Why a session ended. The runner always says; `unknown` is a bug to chase, not a category.",
    values: {
      exited: "The agent exited on its own (see `code`).",
      killed: "Someone pressed Kill, or the task was cancelled.",
      signaled: "The process died from a signal nobody here sent (see `signal`).",
      outOfMemory: "The OS killed it for memory (jetsam on macOS, the OOM killer on Linux).",
      machineSlept: "The machine slept; its clock jumped and the pane is gone.",
      tmuxLost: "The runner's tmux server went away with every session on it.",
      runnerUpdated: "The runner restarted for an update and the session didn't survive it.",
      authExpired: "The agent's login expired or was revoked.",
      usageLimit: "The account hit its session or weekly limit.",
      unknown: "None of the above could be shown.",
    },
  },
  AgentState: {
    doc: "What a session's agent is doing, from its hooks.",
    values: {
      working: "Running a turn.",
      waiting: "Waiting on a person: a question, a permission prompt.",
      done: "Finished its turn.",
      idle: "Started, with nothing asked yet.",
    },
  },
};

export const structs: Record<string, Struct> = {
  SessionInfo: {
    fields: { id: "uuid", agent: "string", cwd: "string", pid: "u32?", startedAt: "u64", taskId: "string?" },
    fieldDocs: { taskId: "The task this session works on, when it's a factory session." },
  },
  Activity: {
    doc: "An agent's latest state. `at` is the runner's clock, strictly increasing per session.",
    fields: { state: "AgentState", message: "string?", step: "string?", summary: "string?", question: "json?", at: "u64" },
    fieldDocs: { step: "The plan step or todo it is on, when the agent says." },
  },
  LiveSession: {
    fields: { session: "SessionInfo", activity: "Activity?" },
  },
  SessionEnd: {
    doc: "How a session ended, kept with the task so its card can say why and recovery can decide what to do.",
    fields: {
      id: "uuid",
      cause: "EndCause",
      code: "i32?",
      signal: "string?",
      detail: "string?",
      at: "u64",
      lastOutput: "string[]",
      by: "string?",
    },
    fieldDocs: {
      by: "Who asked for it to end, when someone did (the server fills this in; runners don't know).",
      detail: "The evidence in a sentence, e.g. \"clock jumped 41 min while the pane was alive\".",
      lastOutput: "The screen's last lines when it ended, so the cause can be checked by a person.",
    },
  },
  Battery: { fields: { percent: "f64", charging: "bool" } },
  AgentInstall: {
    doc: "An agent CLI on the machine.",
    fields: { name: "string", version: "string?", loggedIn: "bool" },
  },
  Health: {
    fields: {
      cpu: "f64",
      cores: "u32",
      load1: "f64",
      memUsed: "u64",
      memTotal: "u64",
      diskUsed: "u64",
      diskTotal: "u64",
      uptime: "u64",
      battery: "Battery?",
      agents: "AgentInstall[]",
    },
  },
  Machine: {
    doc: "A machine as the apps see it.",
    fields: {
      id: "string",
      name: "string",
      owner: "string",
      online: "bool",
      lastSeen: "u64?",
      version: "string?",
      os: "string?",
      health: "Health?",
      sessions: "LiveSession[]",
    },
    fieldDocs: { owner: "The GitHub login of the person who enrolled it." },
  },
  EndedSession: {
    doc: "A session end with the machine it was on, for lists.",
    fields: { machine: "string", end: "SessionEnd" },
  },
  Member: {
    fields: { login: "string", name: "string?", avatarUrl: "string?", role: "string", teams: "string[]" },
  },
};

export const unions: Record<string, Union> = {
  RunnerMessage: {
    doc: "Runner → server.",
    variants: {
      hello: {
        doc: "First message on every connection, so a server that missed messages catches up.",
        fields: {
          runnerId: "string",
          hostname: "string",
          os: "string",
          arch: "string",
          version: "string",
          sessions: "LiveSession[]",
          ended: "SessionEnd[]",
        },
        fieldDocs: { ended: "Sessions that ended since the last connection, causes included." },
      },
      health: { fields: { health: "Health" } },
      "session.opened": { fields: { session: "SessionInfo" } },
      "session.error": { fields: { id: "uuid", message: "string" } },
      "session.ended": { fields: { end: "SessionEnd" } },
      "session.activity": { fields: { id: "uuid", activity: "Activity" } },
      "session.replay": {
        doc: "The screen and scrollback asked for by `session.replay`, as bytes that repaint a fresh terminal.",
        fields: { id: "uuid", nonce: "string", data: "string" },
        fieldDocs: { data: "Base64." },
      },
      "update.status": { fields: { state: "string", version: "string?", message: "string?" } },
    },
  },
  ServerToRunner: {
    doc: "Server → runner.",
    variants: {
      "session.open": {
        fields: {
          id: "uuid",
          agent: "string",
          cwd: "string",
          cols: "u16",
          rows: "u16",
          prompt: "string?",
          resume: "bool",
          taskId: "string?",
        },
        fieldDocs: { resume: "Continue the agent's last conversation in `cwd` (claude --resume / codex resume)." },
      },
      "session.resize": { fields: { id: "uuid", cols: "u16", rows: "u16" } },
      "session.kill": { fields: { id: "uuid" } },
      "session.replay": {
        doc: "Send the session's screen and scrollback, so a new viewer starts with what's there.",
        fields: { id: "uuid", nonce: "string" },
        fieldDocs: { nonce: "Echoed in the reply, so it goes to the viewer that asked." },
      },
      "runner.update": {},
      "runner.restart": {},
    },
  },
  ClientMessage: {
    doc: "App (macOS, web) → server.",
    variants: {
      subscribe: { doc: "Start receiving `snapshot` and live updates." },
      "session.open": {
        fields: { machine: "string", agent: "string", cwd: "string", cols: "u16", rows: "u16", prompt: "string?" },
      },
      "session.attach": {
        doc: "Stream a session's terminal to this connection, starting with a replay.",
        fields: { machine: "string", id: "uuid", cols: "u16", rows: "u16" },
      },
      "session.detach": { fields: { id: "uuid" } },
      "session.resize": { fields: { machine: "string", id: "uuid", cols: "u16", rows: "u16" } },
      "session.kill": { fields: { machine: "string", id: "uuid" } },
    },
  },
  ServerToClient: {
    doc: "Server → app.",
    variants: {
      snapshot: {
        fields: { org: "string", me: "Member", machines: "Machine[]", ended: "EndedSession[]", protocolVersion: "u32" },
        fieldDocs: { ended: "The most recent session ends (last 7 days, newest first)." },
      },
      "machine.updated": { fields: { machine: "Machine" } },
      "machine.removed": { fields: { id: "string" } },
      "session.ended": { fields: { machine: "string", end: "SessionEnd" } },
      error: { fields: { message: "string", requestId: "string?" } },
    },
  },
};
