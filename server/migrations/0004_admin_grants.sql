-- Factory-granted admins: someone an admin made admin here, though GitHub doesn't say they're an owner.
-- Kept apart from `role` (what GitHub reports, rewritten at each sign-in), so a sign-in never wipes it.
-- NULL: not granted.
ALTER TABLE members ADD COLUMN admin_granted_by TEXT;
ALTER TABLE members ADD COLUMN admin_granted_at INTEGER;
