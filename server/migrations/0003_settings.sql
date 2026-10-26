-- What /setup learns (the GitHub App's credentials, a session secret), for factories deployed without
-- an installer to set Worker secrets. A Worker secret or var of the same name always wins.
CREATE TABLE settings (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL,
  updated_at INTEGER NOT NULL
);
