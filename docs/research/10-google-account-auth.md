# Connecting a Google account from a native Swift macOS app (YouTube upload)

Research date: 2026-09-09. Sources are Google's and Apple's own documentation plus GitHub metadata fetched today; "last updated" dates are the ones printed on the pages. Facts marked *[memory]* could not be re-verified against a primary source today and should be treated as background, not citation. Nothing here has been run; the "spike" items at the end are the things to try first.

## 1. Google's OAuth 2.0 for installed apps, as of September 2026

Google's canonical page is [OAuth 2.0 for iOS & Desktop Apps](https://developers.google.com/identity/protocols/oauth2/native-app) (last updated 2026-08-07). What it says today:

- **Client type.** For "macOS, Linux, and Windows desktop (but not Universal Windows Platform) apps" the form value is **Desktop app**. The **iOS** client type takes a bundle identifier (`CFBundleIdentifier`), optional App Store ID and Team ID, and can turn on App Check. There is no separate "macOS" client type; a Mac app that uses Google's own SDK ends up using an iOS-type client because that SDK redirects via the reversed-client-ID custom scheme (see section 5). Google's [OAuth policies](https://developers.google.com/identity/protocols/oauth2/policies) (2026-08-05) require "a separate OAuth client for each platform on which your app will run".
- **Desktop app clients need no redirect configuration.** The console "does not require any additional information to create OAuth 2.0 credentials" for desktop apps ([Manage OAuth Clients](https://support.google.com/cloud/answer/15549257)); the loopback redirect is implicitly allowed. The console generates a client secret for Desktop clients, and Google's own text says that for installed apps "the client secret is obviously not treated as a secret" ([Using OAuth 2.0 to Access Google APIs](https://developers.google.com/identity/protocols/oauth2), 2026-05-26). On the token and refresh endpoints `client_secret` is listed as **Optional** for desktop clients and "not applicable to requests from clients registered as Android, iOS, or Chrome applications". Send it if Google issues one; it buys nothing security-wise but avoids `invalid_client` surprises. Note that clients "inactive for six months are automatically deleted" after a 30-day warning email ([same page](https://support.google.com/cloud/answer/15549257)).
- **PKCE.** "Google supports the Proof Key for Code Exchange (PKCE) protocol to make the installed app flow more secure." Verifier: 43–128 characters from `[A-Za-z0-9-._~]`; challenge: `S256` = base64url (no padding) of SHA-256(verifier). Recommended, not strictly required, but there is no reason to omit it.
- **Redirect options that still work for a Desktop client.**
  - **Loopback IP: `http://127.0.0.1:PORT` or `http://[::1]:PORT`** with a random port — "if your platform supports it, this is the recommended mechanism for obtaining the authorization code." `localhost` also works "but this configuration may cause issues with client firewalls." Loopback is **deprecated only for Android, Chrome app and iOS client types** ([Loopback migration guide](https://developers.google.com/identity/protocols/oauth2/resources/loopback-migration), 2026-05-26: "Desktop apps may continue using loopback IP addresses"). After the redirect the app "should respond by displaying an HTML page that instructs the user to close the browser and return to your app."
  - **Custom URI scheme** (`com.example.app:/oauth2redirect` or `com.googleusercontent.apps.<CLIENT_ID>:/oauth2redirect`). The page's parameter table still documents it and says it is "no longer supported on Android and Chrome apps", but the "App redirect methods" section now carries a blanket "Important: Custom URI schemes are no longer supported due to the risk of app impersonation." The page is internally inconsistent; Google's own macOS SDK still uses a custom scheme (section 5). Treat custom schemes as tolerated-but-disfavoured for a Desktop client and do not build on them.
  - **OOB / manual copy-paste** (`urn:ietf:wg:oauth:2.0:oob`) is gone: blocked for all clients since 2023-01-31 ([OOB migration guide](https://developers.google.com/identity/protocols/oauth2/resources/oob-migration), 2026-05-26).
- **Embedded web views are forbidden.** The policies page: "A developer must not direct a Google OAuth 2.0 authorization request to an embedded user-agent"; the native-app page adds that macOS developers hit `disallowed_useragent` when they open the auth URL in `WKWebView` and should use Google Sign-In or AppAuth (both of which use the system browser on macOS).
- **Incremental authorization is not available to installed apps.** The native-app page: "incremental authorization with installed apps is not supported due to the fact that the client cannot keep the client_secret confidential." So decide the scope set up front (section 4); a later scope increase means a fresh full authorization.
- **"Google Sign-In for macOS"** is not a separate product; it is the macOS target of `GoogleSignIn-iOS`, added in 6.2.0 ([release notes](https://developers.google.com/identity/sign-in/ios/release)), and still maintained (10.0.0 released 2026-09-04).

## 2. The Apple side

### `ASWebAuthenticationSession` on macOS

[Apple docs](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession): macOS 10.15+. "In macOS, the system opens the user's default browser if it supports web authentication sessions, or Safari otherwise." The OS "ensures that only the calling app's session receives the authentication callback, even when more than one app registers the same callback URL scheme." Facts that matter for this app:

- Initializers: `init(url:callback:completionHandler:)` with [`ASWebAuthenticationSession.Callback`](https://developer.apple.com/documentation/authenticationservices/aswebauthenticationsession/callback) `.customScheme("...")` or `.https(host:path:)` — **macOS 14.4+**. The older `init(url:callbackURLScheme:completionHandler:)` is marked deprecated. The `.https` callback is meant for universal-link style callbacks; a third-party default browser must declare `CallbackURLMatchingIsSupported` in its `ASWebAuthenticationSessionWebBrowserSupportCapabilities` or the system falls back to Safari. Neither Google's loopback redirect nor an `https` callback on a domain you would have to host fits this app, so if you use `ASWebAuthenticationSession` at all it is with `.customScheme`.
- `prefersEphemeralWebBrowserSession` asks the browser for a private session — the user then has to sign in to Google every time. Leave it `false` for a "connect once" flow.
- `presentationContextProvider` is required on macOS too. Apple staff on the [developer forums](https://developer.apple.com/forums/thread/704545): "You still need to set the presentationContextProvider and provide a valid window on Mac ... The anchor window that you provide is used to hint to the system where to show the browser window." Without it: `Cannot start ASWebAuthenticationSession without providing presentation context` (error code 2).
- Running unbundled (an SPM `swift run` executable with no `.app` wrapper) is where this gets shaky: you need an `NSApplication` run loop and an `NSWindow` to anchor, you have no `Info.plist` to register `CFBundleURLTypes`, and whether the session's private callback routing works for a process without a bundle identifier is not documented. Apple's docs describe the API strictly in terms of apps. *[memory]* Community reports say it does work from a minimal AppKit process when a window exists, but that is not something to depend on. Treat "ASWebAuthenticationSession from an unbundled binary" as a spike, not an assumption.
- Not every browser participates. Safari, Chrome, Firefox and Edge implement the web-authentication-session handshake *[memory]*; anything else sends the user to Safari, which may not be where they are signed in to Google. That is a UX wrinkle, not a blocker.

### Loopback listener + default browser

The alternative is exactly what Google recommends for desktop and what AppAuth does on macOS: bind a `127.0.0.1` socket on a random port, open `https://accounts.google.com/o/oauth2/v2/auth?...&redirect_uri=http://127.0.0.1:PORT/callback` with `NSWorkspace.shared.open(_:)`, accept one HTTP request, parse `code` and `state`, reply with a small "you can close this tab" HTML page, and close the socket. Properties:

- Works identically from a signed `.app` and from an unbundled `swift run` binary: no bundle, no `Info.plist`, no entitlements, no window required.
- Uses whatever browser the user actually uses, with their existing Google session.
- Needs nothing from Authentication Services. `Network.framework` (`NWListener` on `127.0.0.1`, port `0`) or a raw BSD socket is enough; the request is one `GET` line plus headers, so you do not need an HTTP library.
- Security notes: bind to `127.0.0.1` only (never `0.0.0.0`), check `state`, stop listening after the first hit or a timeout, and rely on PKCE to make an intercepted code useless. Google's own note that the loopback flow is "vulnerable to man in the middle attacks where a nefarious app ... may intercept the response" is why it was withdrawn on mobile; on a desktop with PKCE and a random port it remains their recommended option.

### Keychain

- macOS has two keychains ([TN3137](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)): the legacy **file-based** keychain (ACL-based, `SecAccess`) and the **data protection** keychain (iOS model). Apple says to "default to the data protection keychain" by passing `kSecUseDataProtectionKeychain: true` ([docs](https://developer.apple.com/documentation/security/ksecusedataprotectionkeychain), macOS 10.15+; "highly recommended ... for all keychain operations").
- `kSecAttrAccessible` ([docs](https://developer.apple.com/documentation/security/ksecattraccessible)) on macOS "can only be used if you also set `kSecUseDataProtectionKeychain` to true, or `kSecAttrSynchronizable` to true, or both." Values: `WhenUnlocked`, `AfterFirstUnlock`, `WhenPasscodeSetThisDeviceOnly`, and the `ThisDeviceOnly` variants; synchronizable items may not use `ThisDeviceOnly`.
- The catch from TN3137: data-protection keychain access "needs keychain access group entitlements from `com.apple.security.application-groups` or `com.apple.keychain-access-groups`", authorized by a provisioning profile, which "is standard for app and app extensions but not for command-line tools." So a Developer-ID-signed `.app` with a provisioning profile can use the data-protection keychain; an unbundled `swift run` binary cannot, and must fall back to the file-based keychain (plain `SecItemAdd` without the data-protection key), which works but ties the item's ACL to the code signature — every rebuild of an ad-hoc-signed binary produces a "wants to use your confidential information" prompt or an access failure *[memory]*. GoogleSignIn's README says the same thing from the other side: "in order for your macOS app to store credentials via the Keychain on macOS, you will need to add `$(AppIdentifierPrefix)$(CFBundleIdentifier)` as the first item in its keychain access group."

## 3. Token handling

From [Using OAuth 2.0 to Access Google APIs](https://developers.google.com/identity/protocols/oauth2) (2026-05-26) and the native-app page:

- **Access tokens** live about an hour (`expires_in`, seconds). Refresh proactively when within a minute of expiry; treat `401` with `invalid_token` as "refresh and retry once".
- **Refresh tokens** are issued on the first authorization of a client for an account. The token exchange must include `code_verifier`; for installed apps `access_type=offline` is implied (you always get a refresh token *[memory]*; pass `access_type=offline` anyway, it is harmless). They stop working when: the user revokes access; unused for six months; the account exceeds **100 live refresh tokens per client ID** (oldest is silently invalidated); the user changed password and the token has Gmail scopes; time-based access expired; a Workspace admin restricted the service.
- **Testing status: 7-day expiry.** "A Google Cloud project with an OAuth consent screen configured for an external user type and a publishing status of 'Testing' is issued a refresh token expiring in 7 days, unless the only OAuth scopes requested are a subset of name, email address, and user profile." The [Audience page](https://support.google.com/cloud/answer/15549945) says the same: "Authorizations by a test user will expire seven days from the time of consent." A YouTube scope is never in that subset, so a Testing-mode project means re-connecting weekly. That is fine for development and painful for anyone else.
- **Revocation:** `POST https://oauth2.googleapis.com/revoke?token=<access or refresh token>`, `Content-Type: application/x-www-form-urlencoded`; `200` on success, `400` if the token is already invalid. Revoking a refresh token also kills its access tokens. Google's policies require you to "revoke tokens when you no longer need access", and the YouTube developer policies require an in-app disconnect (section 4). Users can also revoke at `https://myaccount.google.com/permissions` / `https://security.google.com/settings/security/permissions`.
- **Incremental authorization** is documented for web/server apps (ask for Calendar only when the user clicks "Add to Calendar"; `include_granted_scopes=true` merges grants), but the native-app page explicitly says it is not supported for installed apps. Ask for everything you need in one consent.
- **Storing:** one Keychain item (generic password, `kSecAttrService = "<bundle id>.google"`, `kSecAttrAccount = <Google account id (sub) or channel id>`) whose data is a small JSON blob `{refresh_token, scope, client_id, granted_at, account_sub, channel_id}`. Keep the access token in memory only; it is cheap to refresh. `kSecAttrAccessibleAfterFirstUnlock` is enough (uploads may run while the screen is locked); use `WhenUnlockedThisDeviceOnly` if you would rather the token never leave the machine via iCloud Keychain.

## 4. Scopes, verification, and what ships without verification

**YouTube Data API scopes** ([installed-apps guide](https://developers.google.com/youtube/v3/guides/auth/installed-apps), 2026-08-07):

| Scope | Consent text | Needed for |
|---|---|---|
| `https://www.googleapis.com/auth/youtube.upload` | Manage your YouTube videos | `videos.insert`, `thumbnails.set` on your own uploads |
| `https://www.googleapis.com/auth/youtube.readonly` | View your YouTube account | `channels.list mine=true` for the "Connected as" display, playlists list |
| `https://www.googleapis.com/auth/youtube` | Manage your YouTube account | Superset: upload + edit + playlists + delete |
| `https://www.googleapis.com/auth/youtube.force-ssl` | See, edit, and permanently delete your YouTube videos, ratings, comments and captions | Captions (`captions.insert`) and comments; also a superset for upload |
| `openid email profile` | basic profile | `userinfo` for the Google account name/email/avatar (non-sensitive) |

[`videos.insert`](https://developers.google.com/youtube/v3/docs/videos/insert) (2026-09-04) accepts `youtube.upload`, `youtube`, `youtubepartner`, or `youtube.force-ssl`; files up to 256 GB; resumable endpoint `POST https://www.googleapis.com/upload/youtube/v3/videos`. [`channels.list`](https://developers.google.com/youtube/v3/docs/channels/list) costs 1 unit; the `youtube.upload` scope is upload-only, so add `youtube.readonly` if you want to read the channel (the docs do not state this in one place, but the consent strings above make the split clear; verify in the spike).

**Classification.** Google sorts scopes into non-sensitive, sensitive, and restricted ([Manage App Data Access](https://support.google.com/cloud/answer/15549135)). The [restricted-scope list](https://support.google.com/cloud/answer/13464325) is Gmail, Drive, Fit, Chat, Health, Photos Ambient and the Data Portability API (which has `dataportability.youtube.*` scopes, unrelated to the Data API). **No YouTube Data API scope is restricted; all of the YouTube Data API scopes, including `youtube.readonly`, are sensitive.** This is *[memory]* for the exact console badge (the classification is only shown in the Cloud Console when you add the scope, and no Google page fetched today prints the list); secondary sources agree, and the restricted list above is authoritative for "not restricted". Sensitive scopes never require the CASA security assessment that restricted scopes do.

**Publishing status** ([Audience page](https://support.google.com/cloud/answer/15549945); [Unverified apps](https://support.google.com/cloud/answer/7454865)):

| | Testing | In production, unverified | In production, verified |
|---|---|---|---|
| Who can authorize | Up to **100 named test users** (quota is not reset when you remove users) | Anyone, but only **100 new users total** after the "unverified app" screen appears | Anyone |
| Refresh token life | **7 days** (YouTube scopes are not in the basic-profile exemption) | Normal | Normal |
| Consent UI | "This app hasn't been verified" warning; the tester sees the app name from the consent screen config | Full-page "Google hasn't verified this app" interstitial with an Advanced link to continue | Normal consent with app name and logo |
| Verification needed | No | No (but capped) | Yes |

**Verification** ([Sensitive scope verification](https://developers.google.com/identity/protocols/oauth2/production-readiness/sensitive-scope-verification), 2026-08-19): a public homepage on a domain you verify in Search Console; a privacy policy "hosted within the same domain as your application's home page"; app name and logo that match the app; a YouTube-hosted demo video showing the consent flow, the app name, the client ID in the browser address bar, and how each sensitive scope is used; a written justification per scope and why a narrower one will not do. "Typically takes 3-5 business days". Apps that only use non-sensitive scopes can do the lighter "brand verification" just to show a name and logo ([App verification](https://support.google.com/cloud/answer/13463073)).

**YouTube's separate compliance layer.** Independently of OAuth verification, [videos.insert](https://developers.google.com/youtube/v3/docs/videos/insert) states: "All videos uploaded via the `videos.insert` endpoint from unverified API projects created after 28 July 2020 will be restricted to private viewing mode." Lifting that requires the [YouTube API Services compliance audit](https://developers.google.com/youtube/v3/guides/quota_and_compliance_audits) (2026-09-04), which is the same form used for quota extensions. The default quota (same page and [quota costs](https://developers.google.com/youtube/v3/determine_quota_cost)) is now bucketed: **100 `videos.insert` calls per day, 100 `search.list` per day, and 10,000 units/day for everything else** (`channels.list` = 1 unit). One hundred uploads a day is far more than a single-user editor needs; the private-only restriction is the real constraint for an unaudited project. The [YouTube API Services Developer Policies](https://developers.google.com/youtube/terms/developer-policies) (2026-06-24) also require: a link to YouTube's Terms of Service and agreement before use; a privacy policy that says the app uses YouTube API Services and links Google's privacy policy; an in-app way to revoke access plus a pointer to `https://security.google.com/settings/security/permissions`; authorized data refreshed or deleted after 30 days and deleted within 7 days of revocation; and no altering of user-supplied upload metadata without consent.

**What a single developer can ship without verification.** Keep the project in **Testing** with your own account as the test user: no verification, no interstitial beyond the "unverified" warning, uploads work, and uploads land as **private** (which is also the safe default for an editor — the user can flip visibility in Studio). The cost is the 7-day refresh-token expiry, i.e. a weekly "Reconnect YouTube" click. Moving to production unverified buys nothing you want (100-user cap, scarier interstitial, still private-only uploads). Verification (3–5 business days, needs a website, privacy policy and a demo video) plus the YouTube compliance audit is the path to a public release with public uploads, and it does not require an LLC or fees; budget a week of elapsed time and a domain.

## 5. Swift options

Metadata from the GitHub API on 2026-09-09.

| Option | Version / date | Licence | Platforms | SPM | Language | What you get | Verdict |
|---|---|---|---|---|---|---|---|
| [GoogleSignIn-iOS](https://github.com/google/GoogleSignIn-iOS) | 10.0.0, 2026-09-04; 751 stars, 86 open issues | Apache-2.0 | macOS 12+, iOS 15+ | Yes (`GoogleSignIn`, `GoogleSignInSwift`) | Obj-C, SwiftUI button | `GIDSignIn.signIn(withPresenting: NSWindow)`, `addScopes`, keychain persistence via GTMAppAuth, Google-branded SwiftUI button, App Check | Heaviest: pulls AppAuth, GTMAppAuth, GTMSessionFetcher, app-check, GoogleUtilities. On macOS it redirects to the **reversed-client-ID custom scheme** (`GIDSignInCallbackSchemes`, `redirectURLWithOptions`) and asserts at startup if your `Info.plist` does not declare it, so it needs an app bundle and an iOS-type client; it will not run unbundled. Built for "sign in", not "connect an account". |
| [GTMAppAuth](https://github.com/google/GTMAppAuth) | 6.0.0, 2026-08-28; 448 stars | Apache-2.0 | macOS 12+ | Yes | Swift (5.x, Swift 6 fixes landed) | `AuthSession` + `KeychainStore` for AppAuth state; authorizer for GTMSessionFetcher | Only useful on top of AppAuth; adds GTMSessionFetcher (which you do not need with `URLSession`). |
| [AppAuth-iOS](https://github.com/openid/AppAuth-iOS) | 3.0.0, 2026-08-24; 2,029 stars, 235 open issues | Apache-2.0 | macOS 12+ | Yes (`AppAuth`, `AppAuthCore`) | Obj-C (~790 kLOC Obj-C, 4 kLOC Swift) | Full OAuth/OIDC client with PKCE; on macOS `OIDExternalUserAgentMac` uses `ASWebAuthenticationSession` on 10.15+ (with `presentationContextProvider` and ephemeral flag) and falls back to `NSWorkspace.openURL`; `OIDRedirectHTTPHandler` starts a loopback HTTP server on `127.0.0.1` with a random port | Solid and current (3.0.0 was the Xcode 27 bump). But it is a large Objective-C surface, its `OIDAuthState` persistence is `NSCoding` blobs, and its Swift ergonomics (NSError-based callbacks, `resumeExternalUserAgentFlow`) are dated. Justified if you needed OIDC discovery or many providers; overkill for one Google client. |
| Hand-rolled `URLSession` + PKCE | n/a | n/a | Whatever you target | n/a | Swift 6 | ~300 lines: PKCE, loopback listener, three HTTP calls, Keychain item | Zero dependencies, runs bundled or unbundled, trivially testable with a stub token endpoint, and matches exactly the flow Google documents for desktop. Cost: you own the edge cases (state check, timeout, error JSON, retry on refresh). |

Google's SDK is the only one that gives you the branded button, but a **"Connect YouTube" button is not a Sign in with Google button** (section 7), so that advantage does not apply. Recommendation: **hand-rolled**. If the flow later has to cover several providers or OIDC discovery, AppAuth 3.x is the fallback and its `OIDRedirectHTTPHandler` is a good reference for the loopback server.

## 6. Identity for the "Connected as" state

Two calls, both cheap:

- `GET https://www.googleapis.com/youtube/v3/channels?part=snippet,statistics&mine=true` with `Authorization: Bearer <access_token>` (1 quota unit). Use `items[0].id` (channel ID, stable key for the Keychain item), `items[0].snippet.title`, `items[0].snippet.customUrl` (the `@handle`), `items[0].snippet.thumbnails.default.url` (88×88 avatar), and optionally `statistics.subscriberCount`. Requires `youtube.readonly` or a superset. An account with no channel returns an empty `items` array — show "No YouTube channel on this account" and link to `https://www.youtube.com/create_channel`.
- `GET https://openidconnect.googleapis.com/v1/userinfo` (needs `openid email` and/or `profile`, all non-sensitive) returns `sub`, `email`, `name`, `picture` ([OpenID Connect](https://developers.google.com/identity/openid-connect/openid-connect), 2026-06-15). `sub` is the stable account key; Google warns against keying on `email`. The `id_token` in the token response carries the same claims if you include `openid` in the scope, which saves a round trip.

Show: channel avatar, channel title, `@handle`, and the Google account email in smaller type, plus a "Disconnect" button (revokes the refresh token and deletes the Keychain item) and a "Manage access" link to `https://myaccount.google.com/permissions`. Because the token in Testing status dies after 7 days, the state also needs an "expired, reconnect" variant driven by an `invalid_grant` on refresh. Brand channels matter here: a Google account can own several channels; `mine=true` returns the channel the user picked on the consent screen's account chooser, so if the wrong one shows up the answer is "Disconnect, reconnect, choose the brand channel".

## 7. Branding and consent-UI rules

- The [Sign in with Google branding guidelines](https://developers.google.com/identity/branding-guidelines) (2026-07-07) govern **sign-in** buttons: "Sign in with Google" / "Sign up with Google" / "Continue with Google" wording, the unmodified gradient "G" on a white tile, specified fills/strokes (#FFFFFF/#747775/#1F1F1F light; #131314/#8E918F/#E3E3E3 dark), and parity of prominence with other third-party sign-in options. "Following these guidelines on displaying the Sign in with Google button is required for app verification." A "Connect YouTube account" action that only authorizes API access is not a sign-in button; use a neutral button ("Connect YouTube…") and do not put the Google "G" or "Sign in with Google" text on it unless you also treat it as the app's sign-in. YouTube's own logo use falls under [YouTube brand guidelines](https://www.youtube.com/howyoutubeworks/resources/brand-resources/) *[memory]* — an unmodified YouTube icon next to "Connect" is the normal pattern.
- OAuth policy requirements that show up in the UI: the consent screen name and logo must "accurately represent the identity of the application"; request "the smallest set of scopes that are necessary for providing functionality knowingly chosen by the user"; a production app needs "a publicly accessible home page" with privacy policy and terms links on a verified domain ([OAuth policies](https://developers.google.com/identity/protocols/oauth2/policies)).
- YouTube-specific (section 4): show the YouTube Terms of Service link and get agreement before the first upload, say in the privacy policy that the app uses YouTube API Services and link Google's privacy policy, and provide the in-app disconnect.

## Recommendation for this app

Context: SPM-built, Developer-ID-signed macOS app that also runs unbundled during development; one user, one Google account at a time, offline refresh tokens.

1. **Create one OAuth client of type "Desktop app"** in a project with an External consent screen in **Testing** status; add your own Google account(s) as test users. Enable the YouTube Data API v3. Configure the consent screen with the app name and, when you have them, homepage and privacy policy. Accept the 7-day token life until you decide to verify. Embed the client ID (and the generated secret, which is not secret) in the app as constants.
2. **Scopes, requested once:** `openid email https://www.googleapis.com/auth/youtube.upload https://www.googleapis.com/auth/youtube.readonly`. Add `youtube.force-ssl` only when caption upload lands (it replaces `youtube.upload`). No incremental auth on desktop, so a scope change = disconnect + reconnect.
3. **Redirect: loopback listener + default browser**, hand-rolled. It is Google's recommended desktop mechanism, needs no bundle, `Info.plist`, entitlements, window or Authentication Services, so the same code runs from `swift run` and from the signed `.app`. Do not use `ASWebAuthenticationSession` for Google: its custom-scheme path is the one Google is walking away from, and it is unproven unbundled.
4. **Storage:** Keychain generic-password item, JSON payload as in section 3. In the signed `.app` (with a provisioning profile that grants `keychain-access-groups`) use `kSecUseDataProtectionKeychain: true` + `kSecAttrAccessibleAfterFirstUnlock`. Detect the unbundled/dev case (`Bundle.main.bundleURL.pathExtension != "app"`) and fall back to the file-based keychain without the data-protection key, accepting rebuild prompts; or, simpler, keep a dev-only token file under `~/Library/Application Support/<app>/dev-google-token.json` with `0600` permissions and never ship that path.
5. **Lifecycle:** refresh when the access token is within 60 s of expiry; on `invalid_grant` from refresh, drop to the "Reconnect" state; "Disconnect" = `POST /revoke` then delete the item. Fetch `channels.list mine=true` right after connecting and cache title/handle/avatar URL in the same Keychain payload so the UI can render offline.
6. **Ship plan:** development and personal use in Testing; before any external user, verify the app (homepage + privacy policy + demo video, 3–5 business days) and file the YouTube compliance audit so uploads can be public. Until then, always upload with `status.privacyStatus = "private"` and say so in the UI.

### Exact HTTP sequence

Values in angle brackets are yours. All bodies are `application/x-www-form-urlencoded`.

**0. PKCE and state (per attempt)**

```
code_verifier  = base64url(32 random bytes)            // 43 chars, no padding
code_challenge = base64url(SHA256(code_verifier))       // no padding
state          = base64url(16 random bytes)
listener       = bind 127.0.0.1:0  ->  PORT
redirect_uri   = http://127.0.0.1:PORT/callback
```

**1. Authorization request** — open in the default browser with `NSWorkspace.shared.open`:

```
https://accounts.google.com/o/oauth2/v2/auth
  ?client_id=<CLIENT_ID>.apps.googleusercontent.com
  &redirect_uri=http%3A%2F%2F127.0.0.1%3A<PORT>%2Fcallback
  &response_type=code
  &scope=openid%20email%20https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fyoutube.upload%20https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fyoutube.readonly
  &code_challenge=<code_challenge>
  &code_challenge_method=S256
  &state=<state>
  &access_type=offline
  &prompt=consent
  &login_hint=<email, optional, on reconnect>
```

`prompt=consent` forces the consent page so a refresh token is issued even if the user granted this client before *[memory]*; drop it once you have verified you always get one. The browser lands on `http://127.0.0.1:PORT/callback?state=...&code=...` (or `?error=access_denied`). Verify `state`, reply `200 text/html` with "You can close this tab", close the listener.

**2. Code exchange**

```
POST https://oauth2.googleapis.com/token
Content-Type: application/x-www-form-urlencoded

client_id=<CLIENT_ID>.apps.googleusercontent.com
&client_secret=<CLIENT_SECRET>            // optional for Desktop clients; include if issued
&code=<code>
&code_verifier=<code_verifier>
&grant_type=authorization_code
&redirect_uri=http://127.0.0.1:<PORT>/callback   // must match step 1 exactly
```

Response `200`:

```json
{ "access_token": "ya29...", "expires_in": 3599, "refresh_token": "1//0g...",
  "scope": "openid https://www.googleapis.com/auth/youtube.upload ... ", "token_type": "Bearer",
  "id_token": "eyJ..." }
```

Check `scope` contains what you asked for (the user can untick scopes on the consent screen). Persist `refresh_token`; decode `id_token` for `sub`/`email` (no signature check needed for a token you received directly from Google over TLS, per Google's OIDC doc).

**3. Refresh** (whenever `now > issued_at + expires_in - 60s`)

```
POST https://oauth2.googleapis.com/token
Content-Type: application/x-www-form-urlencoded

client_id=<CLIENT_ID>.apps.googleusercontent.com
&client_secret=<CLIENT_SECRET>            // same rule as above
&refresh_token=<refresh_token>
&grant_type=refresh_token
```

`200` returns a new `access_token` + `expires_in` (no new refresh token). `400 {"error":"invalid_grant"}` means revoked/expired (including the 7-day Testing expiry): delete the stored token and show "Reconnect".

**4. Identity**

```
GET https://www.googleapis.com/youtube/v3/channels?part=snippet,statistics&mine=true
Authorization: Bearer <access_token>
```

**5. Revoke (Disconnect)**

```
POST https://oauth2.googleapis.com/revoke?token=<refresh_token>
Content-Type: application/x-www-form-urlencoded
```

`200` or `400` (already invalid) both mean "delete the Keychain item and clear the UI".

**6. Upload (for completeness; detailed in the upload research when it exists)**

```
POST https://www.googleapis.com/upload/youtube/v3/videos?uploadType=resumable&part=snippet,status
Authorization: Bearer <access_token>
Content-Type: application/json; charset=UTF-8
X-Upload-Content-Type: video/mp4
X-Upload-Content-Length: <bytes>

{ "snippet": { "title": "...", "description": "...", "categoryId": "22" },
  "status":  { "privacyStatus": "private", "selfDeclaredMadeForKids": false } }
```

Then `PUT` the bytes to the `Location` URL returned, resuming with `Content-Range` on failure.

### Spikes before committing

1. Unbundled `swift run` binary: loopback listener + `NSWorkspace.open` + token exchange end to end with a Desktop client in Testing status; confirm a refresh token is returned without `prompt=consent`, and that `channels.list mine=true` works with `youtube.upload youtube.readonly`.
2. Signed `.app`: `SecItemAdd` with `kSecUseDataProtectionKeychain: true` under Developer ID with a provisioning profile; confirm no prompt and that the item survives a rebuild.
3. Confirm the 7-day expiry behaviour by leaving a token for a week (or reading `invalid_grant` on day 8) so the "Reconnect" UI is exercised before anyone else sees it.
