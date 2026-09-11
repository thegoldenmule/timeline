# Configuring the Google client from the Publishes panel

Status: in progress, 2026-09-11. Companion to `docs/design/publish-plan.md` (D3) and
`docs/design/publish-setup.md` (the Google-side checklist, steps 1 to 4, which no UI can do for you).

## Why the panel could not do it

Three separate reasons, none of them a decision to keep the client out of the UI:

1. `GoogleClientConfiguration.load` reads the client from the environment or a JSON file, and nothing
   ever writes one. Step 5 of `publish-setup.md` is a `cp` into `~/Library/Application Support/Timeline`.
2. `PublishingServices.make` runs once in `AppServices.boot`. The account provider and the YouTube
   publisher are built from that snapshot and held as `let`s, so even a client that appeared on disk
   later would need a relaunch.
3. `PublishSection` renders the `publishes` ledger and nothing else; Connect lives in the Settings
   window (`AccountView`), and the setup text there is a paragraph of environment variables.

## What changes

- **Contracts** gains `PublishClient` (clientId, whether a secret is held, `audited`, where it came
  from, whether the app may overwrite it) and `PublishClientStore` (`current`, `save`, `importJSON`,
  `remove`). The UI target sees only this; PublishKit implements it.
- **PublishKit** gains `GoogleClientFile`, which writes the flat
  `{"client_id", "client_secret", "audited"}` form at the first writable candidate path (mode 0600),
  and `GoogleClientConfiguration.resolve`, which reports the source as well as the value. A client set
  through `TIMELINE_GOOGLE_CLIENT_ID` still wins the lookup, so the store reports it as not editable
  and the panel says so rather than writing a file that would be ignored.
- `GoogleAccountProvider.reconfigure` swaps the OAuth client in place (the actor rebuilds its
  `GoogleOAuthClient` and drops cached access tokens); `YouTubePublisher.setAudited` moves the
  forced-private rule behind a `Mutex`. Both keep their existential identity, which is what lets the
  tool context, the sheet, and the account model carry on pointing at the same objects.
- **`PublishingServices` becomes a reference type.** In `.auto` it always builds the provider and the
  publisher, so the switch from "no client" to "client" is a reconfiguration rather than a rebuild.
  `apply(_:)` reconfigures both, updates `state`, and registers or unregisters `publish_youtube` and
  `publish_status` on the registry, so the agent's tool list follows the window without a relaunch.
- **The Publishes panel** gets, above the history: the client card (client id and source when one is
  configured; ID/secret fields and a "Choose client_secret_*.json..." button when none is), the
  connect button with its consent sentence, and the connected-channel rows. The same two views are
  what Settings shows, so there is one implementation of each.

## What it still does not do

Steps 1 to 4 of `publish-setup.md` — the Cloud project, enabling the Data API, the consent screen, and
creating the Desktop client — happen in a browser on Google's side. The panel links to the console and
tells you which of them is missing when the connect fails; it cannot do them for you.
