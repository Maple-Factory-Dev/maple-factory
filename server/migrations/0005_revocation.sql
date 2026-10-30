-- Cutting someone off. revoked_at: when their access was taken away (an admin's "Revoke access", or a
-- re-check found they'd left the org); a web session issued before it no longer works. NULL: never.
-- checked_at: the last time GitHub confirmed they may still sign in; the server asks again once it's stale.
ALTER TABLE members ADD COLUMN revoked_at INTEGER;
ALTER TABLE members ADD COLUMN checked_at INTEGER;
