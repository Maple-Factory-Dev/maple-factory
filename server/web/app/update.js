// Whether this tab is running an older web app than the factory now serves. The app keeps the
// maple-server version from its first snapshot; a deploy restarts the hub, the socket reconnects, and
// a snapshot with a different version means the page should be reloaded to get the new bundle.

/** True when both versions are known and differ; a missing one (an older server, no snapshot yet) never is. */
export function bundleStale(loaded, current) {
  return typeof loaded === "string" && typeof current === "string" && loaded !== "" && current !== "" && loaded !== current;
}
