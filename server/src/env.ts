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
  /** Linear: verifies its webhook at /integrations/linear; the API key lets the bot comment back. */
  LINEAR_WEBHOOK_SECRET?: string;
  LINEAR_API_KEY?: string;
  /** The label that sends an issue to the factory (default "maple"). */
  LINEAR_LABEL?: string;
  /** For tests: where Linear's API is. */
  LINEAR_API_URL?: string;
  /** Jira: the secret in the webhook URL (/integrations/jira?secret=…), the site (https://acme.atlassian.net)
   *  and an account's email and API token for the bot's comments. */
  JIRA_WEBHOOK_SECRET?: string;
  JIRA_SITE?: string;
  JIRA_EMAIL?: string;
  JIRA_API_TOKEN?: string;
  JIRA_LABEL?: string;
}
