export interface Env {
  DB: D1Database;
  ORG: DurableObjectNamespace;
  MACHINE: DurableObjectNamespace;
  RELEASES: R2Bucket;
  GITHUB_ORG: string;
  GITHUB_CLIENT_ID?: string;
  GITHUB_CLIENT_SECRET?: string;
  SESSION_SECRET?: string;
  DEV_LOGIN?: string;
  /** A shared secret for posting requests to /api/intake from outside (Bearer mfi_…). */
  INTAKE_KEY?: string;
  /** Verifies Slack's slash commands at /integrations/slack/command. */
  SLACK_SIGNING_SECRET?: string;
}
