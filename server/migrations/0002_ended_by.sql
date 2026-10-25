-- Who asked for a session to end (Kill), filled in by the server.
ALTER TABLE session_ends ADD COLUMN ended_by TEXT;
