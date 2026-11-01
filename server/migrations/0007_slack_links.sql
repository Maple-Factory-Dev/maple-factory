-- A Slack account paired with a factory member, so @Maple knows who's asking (`@Maple link` in Slack, confirmed on
-- the web while signed in). One row per member and one member per Slack account. Revoking a member deletes the row.
CREATE TABLE slack_links (
  login TEXT PRIMARY KEY,
  slack_user TEXT NOT NULL,
  slack_team TEXT NOT NULL,
  linked_at INTEGER NOT NULL
);
CREATE UNIQUE INDEX slack_links_account ON slack_links (slack_team, slack_user);

-- One-time link codes from `@Maple link`: the SHA-256 of the code (the code itself is only in the ephemeral message),
-- the Slack account it was minted for, and when it stops working (ms). Redeeming deletes it.
CREATE TABLE slack_link_codes (
  hash TEXT PRIMARY KEY,
  slack_user TEXT NOT NULL,
  slack_team TEXT NOT NULL,
  expires_at INTEGER NOT NULL
);
