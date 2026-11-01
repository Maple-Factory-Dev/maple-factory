-- Each member's GitHub user token from their last sign-in, so the factory can act as them on GitHub (approve a pull
-- request when they approve on the Factory). Sealed with AES-GCM under SECRETS_KEY (info "member-github-token v1",
-- the login as additional data): iv || ciphertext, base64url. refresh_token: NULL when GitHub gave none (a token that
-- doesn't expire). expires_at: when the access token stops working (ms), NULL: never. Revoking a member deletes the row.
CREATE TABLE member_github_tokens (
  login TEXT PRIMARY KEY,
  access_token TEXT NOT NULL,
  refresh_token TEXT,
  expires_at INTEGER,
  updated_at INTEGER NOT NULL
);
