# Native session view: research note

Status: research and contract (MF-199). The wire types are in `protocol/schema.ts` (`SessionEvent`, `SessionInput`,
`session.subscribeEvents` / `session.sendInput`). Fixtures are in `protocol/fixtures/session-events/`. Nothing in the
runner or the apps uses them yet.

Sources checked **2026-10-31**.

## The question

We want to show an agent session as a chat (messages, tool cards, diffs, a composer), not only as the tmux
terminal. We must keep two things:

- **Subscription logins** (Claude Pro/Max, ChatGPT plans) keep working.
- **TUI-only features** keep working, Claude's `/rc` (Remote Control) in particular.

Other apps do this in one of two ways.

## (a) Run the agent headless and own the loop

### Claude: `claude -p --input-format stream-json --output-format stream-json`, or the Claude Agent SDK

What you get:

- **Structured streams in both directions.** The first event is `system/init`, which carries the model, tools, MCP
  servers and capabilities.
- **Messages.** Assistant and user messages follow, with subagent messages tagged by `parent_tool_use_id`. With
  `--include-partial-messages` you also get token deltas (`stream_event`).
- **A final `result`.** It carries the cost and `session_id`.
- **Follow-ups.** With stream-json input, queued messages start new turns.
- Docs: <https://code.claude.com/docs/en/headless>, <https://code.claude.com/docs/en/cli-reference>.

What you lose (from the headless docs):

- **Terminal-only built-in commands.** Quote: "Built-in commands that only run in the terminal interface, such as
  `/login`, aren't available."
  - `/model`, `/effort` and similar work only with an argument.
  - Skills and custom commands still work as `/name` in the prompt.
- **The TUI permission menu.** Quote: "In a Manual mode `claude -p` run, a call that needs approval is denied unless
  something approves it, such as a PermissionRequest hook or a --permission-prompt-tool."
  - The SDK answers prompts with a `canUseTool` callback instead.
  - So we would rebuild every prompt ourselves.
- **Remote Control (`/rc`).** It is an interactive-session feature.
  - The CLI reference describes `--rc` as "Start an interactive session with Remote Control enabled".
  - Its limits section says "One remote session per interactive process".
  - It needs a claude.ai login; "API keys are not supported" (<https://code.claude.com/docs/en/remote-control>).
  - No page says outright that `-p` lacks it. That conclusion is our inference from the above.
- **Bare mode.** `--bare` is "recommended for scripted and SDK calls, and will become the default for -p".
  - It skips hooks, skills, plugins, MCP, `CLAUDE.md` and memory.
  - It "never reads OAuth credentials".
  - So the direction of travel for headless is API keys.

**Subscription logins and terms.** This is the deciding point for (a).

- The Agent SDK overview (<https://code.claude.com/docs/en/agent-sdk/overview>) says: "Unless previously approved,
  Anthropic does not allow third party developers to offer claude.ai login or rate limits for their products,
  including agents built on the Claude Agent SDK. Use the API key authentication methods described in the Quickstart
  instead."
- Legal and compliance (<https://code.claude.com/docs/en/legal-and-compliance>) says developers "should use API key
  authentication", and may not "route requests through Free, Pro, Max, or Ultra plan credentials on behalf of their
  users".
- The same page has a carve-out. It does not prevent "an end user from signing in to the unmodified Claude Code binary
  with their own Claude subscription, including where a platform hosts Claude Code". The conditions are:
  - The binary is not modified.
  - Its own auth is kept.
  - The platform doesn't pay for, resell or intermediate the usage.

Running the unmodified `claude` binary in the user's own tmux, logged in through Anthropic's own flow, is the case that
carve-out describes. Driving it from our own loop through the SDK on a claude.ai login is the case the SDK page warns
against.

### Codex: `codex app-server`

Docs: <https://developers.openai.com/codex/app-server>, which now redirects to
<https://learn.chatgpt.com/docs/app-server>.

- **Protocol.** JSON-RPC over stdio (newline-delimited JSON).
  - Threads: `thread/start`, `thread/resume`.
  - Turns: `turn/start`, `turn/steer`, `turn/interrupt`.
  - Notifications: `item/started`, `item/agentMessage/delta`, `item/completed`, `turn/completed`.
  - Items: `agentMessage`, `reasoning`, `commandExecution`, `fileChange`, `mcpToolCall` and others.
- **Approvals.** These are server→client requests: `item/commandExecution/requestApproval` and
  `item/fileChange/requestApproval`.
- **Auth.** `account/login/start` supports `chatgpt` (the user's plan) as well as `apiKey`.
- **Positioning.** OpenAI presents app-server as the protocol for rich clients such as the VS Code extension.
- **In our runner.** We already speak it in `runner/src/usage.rs`, where `account/rateLimits/read` gives plan usage.

app-server is the cleaner of the two headless options. A session run through it is not the TUI, though: no `/`
commands typed into a terminal, and no terminal for a person to fall back to.

### Who does (a)

- **T3 Code** (<https://github.com/pingdotgg/t3code>), checked in its source:
  - Codex runs through `codex app-server` (package `effect-codex-app-server`).
  - Claude runs through `@anthropic-ai/claude-agent-sdk` (`ClaudeProvider.ts`).
  - The README has users run `codex login` / `claude auth login` and says it "Works with your subscriptions".
- **Conductor** (<https://conductor.build>, <https://www.conductor.build/docs/reference/harnesses/claude-code>):
  - It "runs the first-party Claude Code, Codex, Cursor, and OpenCode agents under the hood", with users bringing
    their own subscriptions or keys.
  - Its docs don't say whether it drives Claude through the SDK/`-p` or a terminal. **Unverified.**

## (b) Keep the TUI and mirror its transcript

The agent runs interactively, exactly as now. The view is built from the files the agent already writes:

- **Claude.** `~/.claude/projects/<project>/<session-id>.jsonl`, documented at
  <https://code.claude.com/docs/en/sessions#where-transcripts-are-stored>. Every hook payload carries its path as
  `transcript_path`, a documented common input field (<https://code.claude.com/docs/en/hooks#common-input-fields>).
  The docs warn: "The entry format is internal to Claude Code and changes between versions".
- **Codex.** The rollout JSONL. The app-server doc only says threads persist as a "rollout file".
  - The path `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` is what our runner already relies on (`runner/src/costs.rs`).
  - The path has no official OpenAI page we could find.

Input goes back the way a person's typing does: tmux `send-keys`. So anything the TUI accepts works from the native
composer, including `/rc`, `/compact` and its permission menu.

Pros:

- The subscription login and the terms stay exactly where they are today: the user's own unmodified binary.
- No features are lost.
- The terminal stays one tap away and is always the truth.

Cons:

- We parse an internal format.
- Menus the TUI draws (permission prompts, questions) are not in the transcript.

## Recommendation: (b)

1. **Sessions don't change.** They stay in tmux (`runner/src/sessions.rs`, `runner/src/tmux.rs`).
2. **The runner tails the transcript.**
   - Claude: the runner learns `transcript_path` from the first hook payload (`runner/src/hooks.rs` already reads it
     for the done summary).
   - Codex: the runner finds the rollout the way `runner/src/costs.rs` already does.
3. **It normalises records into `SessionEvent`s.** Each event gets a per-session `seq`. A ring of recent events stays in
   memory, plus a cursor token (file and byte offset), so a restart resumes without a full reread.
4. **Subscribing.** `session.subscribeEvents {since}` sends a backfill (`backfill: true`) of events with `seq > since`,
   then live events. A second subscriber shares the same tail.
   - The server adds a `nonce` to `session.events.subscribe` and the runner echoes it on that backfill, so a backfill
     goes only to the viewer that asked (the `session.replay` pattern); live events carry no nonce and go to every
     subscriber. A viewer joining late never sees another viewer's backfill.
5. **Input.** `session.sendInput` becomes `session.input` to the runner, which types it with
   `send-keys -t … -H <hex>` (as `tmux.rs` already does for terminal input), then Enter.
   - A `key` input picks a prompt option ("1", "Escape"), with the same keys `task.answerPrompt` uses.
   - The server refuses it unless the viewer may type: the machine owner, an admin, or a share with `canType`, the
     same rule as the terminal.
6. **Fallback.** The terminal stays one tap away. If the parser hits records it doesn't know (or a line that isn't
   JSON), it passes them through as a generic `other {kind, summary}` event; it never blocks the session.

We keep (a) in mind for Codex only: app-server could later replace tailing for the read side, while the TUI keeps
running. Not now.

## Mapping: source record → SessionEvent

Checked against the transcripts on this machine (Claude Code with Opus 5.5, Codex 2026-10). Fixtures:
`protocol/fixtures/session-events/`.

### Claude transcript (`transcript_path`)

| Record | Event |
| --- | --- |
| `type: user`, `message.content` a string (not `isMeta`) | `user {text}` |
| `type: user`, content block `tool_result` | `tool.result {callId: tool_use_id, ok: !is_error, text, truncated}` |
| `type: assistant`, block `text` | `assistant {markdown, model}` |
| `type: assistant`, block `thinking` with text | `thinking {text}`. **Empty `thinking` blocks (signature only, the current default) produce nothing** |
| `type: assistant`, block `tool_use` | `tool.call {call: {callId: id, name, summary, path?, diff?, input}}`. For Edit, `diff` is built from `old_string`/`new_string`; for Write, from the new content |
| `type: system`, `subtype: turn_duration` | `turn {state: done, usage}`. Usage comes from the last assistant `message.usage`, duration from `durationMs` |
| `type: system`, `subtype: local_command` with `<command-name>` | `user {text: "/context"}` (slash commands the person ran) |
| `mode`, `permission-mode`, `attachment`, `file-history-*`, `ai-title`, `last-prompt`, `api-request*`, `cost-state` | none |
| Hook `UserPromptSubmit` / `PreToolUse` | `turn {state: running}` |
| Hook `Notification` (`notification_type: permission_prompt`), with the menu read from the pane | `prompt {kind: permission, text, options}` |
| Hook `PostToolUse`, or the next `tool_result` for that call, or `Stop` | `prompt.resolved` |
| Hook `Stop` with an error / Esc in the pane | `turn {state: error / interrupted}` |

### Codex rollout

| Record | Event |
| --- | --- |
| `event_msg` `task_started` | `turn {state: running}` |
| `response_item` `message`, role `user` (not developer / environment context) | `user {text}` |
| `response_item` `message`, role `assistant` | `assistant {markdown}` |
| `response_item` `reasoning` with a `summary` | `thinking {text}`. Empty summaries (the norm here) produce nothing |
| `response_item` `custom_tool_call` / `function_call` | `tool.call`. Today's Codex uses one `exec` tool whose input is a script calling `tools.exec_command(...)`, `tools.apply_patch(...)`; `summary` is the `cmd`, and an `apply_patch` call fills `path` and `diff` from the patch |
| `response_item` `custom_tool_call_output` / `function_call_output` | `tool.result` |
| `event_msg` `token_count` | held; the next `task_complete` carries `last_token_usage` as `usage` |
| `event_msg` `task_complete` | `turn {state: done, usage}` |
| `event_msg` `turn_aborted` | `turn {state: interrupted}` |
| Approval waiting (activity `waiting` from the runner's Codex hooks) | `prompt {kind: permission}` |
| `session_meta`, `world_state`, `turn_context`, `thread_settings_applied`, `item_completed`, `token_usage_record` | none (`item_completed` duplicates the response items) |

## Open risks

- **Format drift.** Both formats are internal. Anthropic says so outright for Claude, and Codex's changed under us: tools
  are now one `exec` script rather than `exec_command`/`apply_patch` calls, and reasoning summaries are mostly empty.
  - Mitigation: pass unknown records through as `other` events and keep fixtures per agent version.
  - Also: emit a `turn {state: error, message}` only for the session, never crash the tail.
  - Also: the terminal is always the fallback.
- **Prompts aren't in the transcript.** The TUI draws permission menus and questions on screen only.
  - The `prompt` events have to come from hooks (`Notification`, plus the activity the runner already tracks) and
    from reading the menu off the pane, as `task.answerPrompt` already does.
  - The options' keys are menu numbers, which differ per prompt, so the runner must read them each time, not assume them.
- **Thinking is mostly invisible.** Current Claude transcripts store thinking blocks with an empty text and a
  signature. Codex reasoning summaries are usually empty. The view should not promise thinking.
- **Cursor semantics.**
  - `seq` is assigned by the runner as it reads, so it is stable only while the runner keeps its state.
  - The cursor `token` (file + byte offset) lets it resume after a restart. After a `/clear`, `/compact` or resume,
    Claude starts a new transcript file. The runner follows the new `transcript_path` from the next hook and keeps
    counting `seq` up, so `since` stays valid.
  - If the runner loses state entirely, it re-reads from the start and numbers `seq` from 1 again, so an old `since`
    would skip or repeat events. Every `session.events` therefore carries an `epoch` naming the current numbering; the
    runner picks a new one whenever it rebuilds the stream from scratch. A client subscribes with `since` plus the
    `epoch` it came from: if that epoch is stale, the runner ignores `since` and sends a full backfill, and a client
    that sees a new epoch on a live message drops what it shows and resubscribes. Clients still dedupe by event `id`.
- **Typing races.** `send-keys` text arriving while the agent is mid-turn is queued by the TUI, same as a person typing.
  - A `key` sent for a prompt that already went away could land in the composer. So `SessionInput.key` names the
    `promptId`, and the runner refuses it unless that prompt is still showing.
- **Size.** Tool outputs and Write contents can be large. Events cut `tool.result.text` at 4000 chars (head and tail) and
  `input` strings. The full content stays in the terminal and the transcript.
- **Retention.** Claude deletes transcripts after `cleanupPeriodDays` (30 by default). Backfill for old sessions may be
  gone; the view then shows only what the runner still holds.
