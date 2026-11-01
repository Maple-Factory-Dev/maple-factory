-- What each machine's runner last detected it can do (a JSON array of tags, e.g. ["arm64","macos","xcode"]),
-- so a machine that's offline still shows its tags.
ALTER TABLE machines ADD COLUMN capabilities TEXT;
