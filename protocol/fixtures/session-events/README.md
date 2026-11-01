# Session event fixtures

Real agent transcripts, cut down and scrubbed (home paths → `/Users/dev`, ids kept, long strings cut, signatures
replaced), each next to the `SessionEvent[]` a runner should turn it into. The contract is `SessionEvent` in
`protocol/schema.ts`; the reasoning is in `docs/native-session-view.md`.

| Source | Expected | What it covers |
| --- | --- | --- |
| `claude.jsonl` (a Claude Code transcript, `transcript_path`) | `claude.expected.json` | user text, empty thinking blocks (skipped), Bash and Edit calls with results, assistant text, `turn_duration` → `turn done`, a local `/context` command |
| `claude.notification.json` (a `Notification` hook payload) | `claude.notification.expected.json` | the permission wait: the TUI never writes its menu to the transcript, so the prompt comes from the hook plus the pane's menu |
| `codex.jsonl` (a Codex rollout under `~/.codex/sessions`) | `codex.expected.json` | `task_started`/`task_complete` → turns, user and assistant messages, empty reasoning (skipped), the `exec` code-mode tool call and its output, `token_count` usage |

Not in the samples, because no rollout on the machine had them: a Codex `apply_patch` call (current Codex runs edits
through the `exec` tool's script) and a non-empty reasoning summary. The runner task should add fixtures when it sees them.

Rules the expected files follow: `seq` starts at 1 and goes up by one per event; an event's `id` is the record's own id
(Claude `uuid`, with `:<n>` when one message holds several blocks; Codex item id, or `<session>:<line>` for turn
markers); `at` is the record's timestamp in ms; empty thinking/reasoning produces no event; tool output is kept whole up to
4000 chars.

`npm run gen:check` validates every `*.expected.json` against the schema and parses every `*.jsonl` line;
`npm run test:fixtures` also proves the checker fails on broken input.

**Consumer:** the runner task that builds the transcript tailer (`session.events.subscribe` → `session.events`), proposed
after MF-199. Its parser tests should read `X.jsonl` and assert the output equals `X.expected.json`.
