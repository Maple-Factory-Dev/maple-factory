export interface Env {
  DB: D1Database;
  ORG: DurableObjectNamespace;
  MACHINE: DurableObjectNamespace;
  /** The factory's files; runner releases here (an org's own builds) win over maplefactory.dev's feed. */
  RELEASES: R2Bucket;
  /** "stable" (default) or "beta": which of the feed's releases runners get. */
  RELEASE_CHANNEL?: string;
  /** Where the official releases come from (default https://maplefactory.dev/releases), or "off". */
  RELEASE_FEED?: string;
  GITHUB_ORG: string;
  GITHUB_CLIENT_ID?: string;
  /** The GitHub App that pushes tasks' branches and opens, merges and closes their pull requests. */
  GITHUB_APP_ID?: string;
  /** The app's URL name (github.com/apps/<slug>), which /setup records for its links. */
  GITHUB_APP_SLUG?: string;
  /** "User" when GITHUB_ORG is someone's personal account (from /setup); otherwise it's an organization. */
  GITHUB_OWNER_TYPE?: string;
  GITHUB_APP_PRIVATE_KEY?: string;
  /** Verifies the app's webhooks (check runs, statuses, pull requests) at /integrations/github. */
  GITHUB_WEBHOOK_SECRET?: string;
  /** For tests: a fake GitHub API on localhost. */
  GITHUB_API_URL?: string;
  /** Where people reach this server, when the request URL can't say (local dev: http://localhost:8788). */
  PUBLIC_URL?: string;
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
