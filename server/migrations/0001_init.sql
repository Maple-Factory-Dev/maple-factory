-- People who have signed in. GitHub org membership decides who may; this remembers what we saw.
CREATE TABLE members (
  login TEXT PRIMARY KEY,
  github_id INTEGER NOT NULL,
  name TEXT,
  avatar_url TEXT,
  role TEXT NOT NULL DEFAULT 'member',      -- 'admin' (GitHub org owner) or 'member'
  teams TEXT NOT NULL DEFAULT '[]',         -- JSON array of team slugs
  created_at INTEGER NOT NULL,
  last_seen INTEGER
);

-- Bearer tokens for the apps (macOS, iOS), from the device flow. Stored hashed.
CREATE TABLE app_tokens (
  token_hash TEXT PRIMARY KEY,
  login TEXT NOT NULL REFERENCES members (login) ON DELETE CASCADE,
  label TEXT,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  last_used INTEGER
);

CREATE TABLE machines (
  id TEXT PRIMARY KEY,                      -- the runner id, e.g. mbp-14
  name TEXT,                                -- display name; NULL shows the id
  owner TEXT NOT NULL,                      -- GitHub login of whoever enrolled it
  token_hash TEXT NOT NULL,
  hostname TEXT,
  os TEXT,
  arch TEXT,
  version TEXT,
  created_at INTEGER NOT NULL,
  last_seen INTEGER
);

CREATE TABLE enroll_codes (
  code_hash TEXT PRIMARY KEY,
  owner TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  used_at INTEGER,
  machine_id TEXT
);

-- Every session end, with its cause and evidence. Kept so a card can say why, and so causes
-- can be counted per machine.
CREATE TABLE session_ends (
  id TEXT PRIMARY KEY,
  machine TEXT NOT NULL,
  task_id TEXT,
  cause TEXT NOT NULL,
  code INTEGER,
  signal TEXT,
  detail TEXT,
  at INTEGER NOT NULL,
  last_output TEXT NOT NULL DEFAULT '[]'
);
CREATE INDEX session_ends_machine ON session_ends (machine, at);

CREATE TABLE audit (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  at INTEGER NOT NULL,
  actor TEXT NOT NULL,
  action TEXT NOT NULL,
  target TEXT,
  detail TEXT
);
