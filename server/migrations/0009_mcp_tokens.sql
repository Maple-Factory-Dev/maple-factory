-- Outside MCP clients (Claude Desktop, Claude Code, Cursor) at /mcp, acting as a member (src/mcp-auth.ts).
-- mcp_tokens: one row per grant. kind 'personal': made in Settings, shown once, no expiry unless set. kind 'oauth':
-- issued by /oauth/token to a registered client; token_hash is the current 1h access token, refresh_hash the current
-- refresh token, both rotated in place on refresh. Tokens are `mfp_…` (access) and `mfr_…` (refresh), kept as sha256
-- only, and only ever accepted at /mcp. scopes: space-separated, from docs:read and docs:write. Revoking a member
-- (auth.ts revokeMember) deletes their rows.
CREATE TABLE mcp_tokens (
  id TEXT PRIMARY KEY,
  token_hash TEXT NOT NULL UNIQUE,
  login TEXT NOT NULL REFERENCES members (login) ON DELETE CASCADE,
  kind TEXT NOT NULL CHECK (kind IN ('personal', 'oauth')),
  client_id TEXT,
  label TEXT,
  scopes TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER,
  last_used INTEGER,
  refresh_hash TEXT UNIQUE,
  refresh_expires_at INTEGER
);
CREATE INDEX mcp_tokens_login ON mcp_tokens (login);

-- OAuth clients that registered themselves (RFC 7591 dynamic registration). Public clients: no secret, PKCE only.
-- redirect_uris: a JSON array of https or loopback http URLs, matched exactly at /oauth/authorize and /oauth/token.
CREATE TABLE oauth_clients (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  redirect_uris TEXT NOT NULL,
  created_at INTEGER NOT NULL
);

-- Authorization codes: 60 seconds, single use (deleted as they're redeemed), bound to the client, the redirect URI
-- and the PKCE S256 challenge.
CREATE TABLE oauth_codes (
  code_hash TEXT PRIMARY KEY,
  client_id TEXT NOT NULL REFERENCES oauth_clients (id) ON DELETE CASCADE,
  login TEXT NOT NULL REFERENCES members (login) ON DELETE CASCADE,
  scopes TEXT NOT NULL,
  code_challenge TEXT NOT NULL,
  redirect_uri TEXT NOT NULL,
  expires_at INTEGER NOT NULL
);
