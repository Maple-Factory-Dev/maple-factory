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
}
