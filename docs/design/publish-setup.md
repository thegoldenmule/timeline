# Publish setup: the Google side, step by step

Status: checklist for the developer, 2026-09-09. Companion to `publish-plan.md` (the design) and
`integration.md` (what the app does with it). Everything here happens in a browser on Google's side or in
one file on this Mac; nothing in the repo changes. The decisions of `publish-plan.md` section 7 apply: the
Cloud project is owned by the user's personal Google account, the consent screen stays in Testing with the
user as the only test user, the compliance audit is filed after the sheet works on a real account, tokens
live in the file store for the unsigned `swift run` binary, and no live test runs until the user says so.

Until step 6 is done the app runs with publishing disabled: Settings shows "Add a Google OAuth client to
enable publishing", `account_status` answers `configured: false`, and `publish_youtube` is not registered.

## 1. A Google Cloud project

1. Sign in to <https://console.cloud.google.com> with the personal account that owns the channel.
2. Create a project. Name it without "YouTube" or "YT" in it (YouTube API policy III.F.2; "Timeline
   Publisher" is fine). Note the project id.
3. Nothing else is needed on the project itself: no billing, no service account.

## 2. Enable the YouTube Data API v3

APIs & Services > Library > search "YouTube Data API v3" > Enable. The quota is 10,000 units per Pacific
day; one upload costs about 1,600 units, so about six uploads a day with thumbnails and captions. The app's
`QuotaMeter` (`<root>/Cache/publish-quota.json`) counts locally and refuses before Google would.

## 3. The OAuth consent screen (Testing, one test user)

APIs & Services > OAuth consent screen (now "Google Auth Platform"):

1. User type External (a personal account cannot make an Internal one).
2. App name (the same one as the project, no "YouTube"), user support email (yours), developer contact (yours).
   Leave the homepage, privacy policy, and terms links empty for now; verification (step 8) needs them,
   Testing does not.
3. Scopes: add `https://www.googleapis.com/auth/youtube.force-ssl` (sensitive) and the non-sensitive
   `openid` and `email`. Justification, if the form asks: "upload videos, set thumbnails, insert caption
   tracks, and add to playlists on the user's own channel". These are the only three scopes the app ever
   requests (`YouTubePublisher.scopes`); the consent screen must list exactly them or the connect fails
   with `denied`.
4. Publishing status: Testing. Add your Google account as a test user. Only test users can connect while
   the project is in Testing, and each connection's refresh token expires after 7 days, at which point the
   account row in Settings turns to "Reconnect required" and `account_status` says `reauthorizationRequired`.
   Both notices the app shows ("This app is not verified by Google yet" and "While the Google Cloud project
   is in Testing, the connection expires after 7 days") describe this state and stay on until steps 8 and 9.

## 4. An OAuth client of type Desktop app

APIs & Services > Credentials > Create credentials > OAuth client ID > Application type "Desktop app".
Name it anything. Download the JSON (`client_secret_<id>.json`). The "client secret" of a Desktop client is
not confidential (Google says so), but the app sends it when present because the token endpoint may answer
`invalid_client` without it. Never commit it: `.gitignore` already excludes `google-oauth-client.json`.

The redirect is the loopback address (`http://127.0.0.1:<random port>/callback`), which Desktop clients
accept without registering anything.

## 5. Where the client goes

Any one of these, checked in this order (`GoogleClientConfiguration.load`, publish-plan.md D3):

1. `TIMELINE_GOOGLE_CLIENT_ID` (and optionally `TIMELINE_GOOGLE_CLIENT_SECRET`) in the environment.
2. `TIMELINE_GOOGLE_CLIENT_JSON=/path/to/client_secret_<id>.json`.
3. `<TIMELINE_ROOT>/google-oauth-client.json` when `TIMELINE_ROOT` is set.
4. `~/Library/Application Support/Timeline/google-oauth-client.json` (the recommended place for the window).

The file may be the console's download as is (`{"installed": {...}}`) or a flat
`{"client_id": "...", "client_secret": "...", "audited": false}`. `audited` (or `TIMELINE_GOOGLE_AUDITED=1`)
is what lifts the forced-private rule in step 9; leave it false until then.

```
mkdir -p ~/Library/Application\ Support/Timeline
cp ~/Downloads/client_secret_*.json ~/Library/Application\ Support/Timeline/google-oauth-client.json
chmod 600 ~/Library/Application\ Support/Timeline/google-oauth-client.json
```

## 6. The first connect

Either from the terminal, without the window:

```
swift run TimelineApp --connect-google
```

or from the window: `swift run TimelineApp`, then Settings (Cmd-,) or the Accounts toolbar button, then
"Connect YouTube...". Both do the same thing: the default browser opens Google's consent page (it shows the
"Google hasn't verified this app" warning; choose Continue), you pick the account and, if it has several,
the channel (a brand channel is a separate choice here; the app publishes to whichever one was picked), you
tick the three scopes, and the page says "You can close this window". The app then reads
`channels.list` and stores:

- the refresh token in `~/Library/Application Support/Timeline/google-tokens.json` (mode 0600; the file
  store the unsigned binary uses, `TIMELINE_TOKEN_STORE=file`; a bundled and signed `.app` switches to the
  Keychain automatically, `TIMELINE_TOKEN_STORE=keychain` forces it);
- the non-secret account record (id, email, channel, handle, avatar URL, scopes, dates) in
  `~/Library/Application Support/Timeline/accounts.json`, which is what Settings and `account_status` show.

Under `TIMELINE_ROOT` both files live in the root instead. Confirm with `account_status` over MCP
(`configured: true`, one account with the channel handle) or the "Connected as" row in Settings.
Disconnect (Settings) revokes the grant with Google, deletes both records, and removes the quota file.

## 7. What "forced private until audit" means

Google keeps every upload from a project that has not passed the YouTube API compliance audit private,
whatever `privacyStatus` the request asked for. The app knows this (`PublishCapabilities.publicUploadsAllowed`
is false while `audited` is false) and:

- the Publish sheet shows "Uploads from this Google Cloud project are private until it passes the YouTube
  compliance audit" under the privacy control, and the approval card warns when anything but private is
  requested;
- `publishAt` (scheduling) cannot work, because a scheduled video needs to become public later;
- the receipt records the privacy YouTube reported and the tool's output carries "Uploaded as private;
  public was requested" when they differ.

Everything else works: the upload, the resume, the thumbnail (a phone-verified channel is needed for custom
thumbnails: <https://www.youtube.com/verify>), captions, playlists.

## 8. Later: the compliance audit

File it once the sheet has published to a real channel a few times (section 7 of publish-plan.md). The
form is at <https://support.google.com/youtube/contact/yt_api_form>; it wants the project id, the app's
homepage and privacy policy (on a domain you own), a demo video of the app using the API, and answers about
data retention (the app keeps tokens only in the store, deletes them and the account record on disconnect,
refreshes channel data after 30 days, and keeps the `publishes` rows as the user's own upload record).
Reviews take several weeks. When it passes, set `"audited": true` in `google-oauth-client.json` (or
`TIMELINE_GOOGLE_AUDITED=1`); public and scheduled uploads then stay as requested.

## 9. Later: OAuth verification and leaving Testing

Not needed while only test users connect. Before anyone else does, submit the consent screen for
verification (APIs & Services > OAuth consent screen > Publish app, then the verification form):
`youtube.force-ssl` is a sensitive scope, so it takes 3 to 5 business days and needs the homepage, the
privacy policy, and a demo video showing the consent flow. Once verified, the warning page disappears, the
7-day expiry ends, and both notices in Settings can be turned off (`PublishingServices.accountNotices`).

## 10. Test channels

- A phone-verified channel for thumbnails and uploads over 15 minutes (the sheet warns about the length).
- Optionally a second, unverified channel to see the `403` on `thumbnails.set` (a warning on the receipt,
  never a failed publish) and the length rejection.

## 11. The opt-in live test

Not run by the agents and not part of `make test`. With a client configured and an account connected through
the file store:

```
TIMELINE_LIVE_YOUTUBE=1 TIMELINE_TOKEN_STORE=file swift test --filter PublishKitTests.LiveYouTubeTests
```

It generates a 2 s clip, uploads it as private with the title `timeline-live-test <date>`, one SRT caption
track, `notifySubscribers=false`, polls until processed, sets a thumbnail (tolerating the `403`), and
deletes the video. Cost: one upload plus about 105 units. Set `TIMELINE_LIVE_TRANSCRIPT_OUT=<file>` to
record the scrubbed exchange for `Tests/PublishKitTests/Transcripts/`.

## 12. Trying the flow without Google

`TIMELINE_PUBLISHING=fake swift run TimelineApp` boots the real `GoogleAccountProvider` and
`YouTubePublisher` against the in-process `FakeYouTubeServer`: "Connect YouTube..." completes without a
browser (the fake presenter performs the loopback callback), the sheet uploads to the fake, and the job
list shows the resumable upload. This is what `make e2e` runs headlessly.
