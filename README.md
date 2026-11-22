# Strapify Messenger for iPhone

A native shell around https://messenger.strapify.com.au/messenger. Everything on screen is the
live web messenger, so **a messenger deploy updates the app instantly with no new build**.

What the shell adds:
- Apple push notifications (reliable, one stack per conversation on the lock screen)
- tapping a notification opens that conversation / message
- camera + microphone for huddles without a second web prompt
- pull to refresh, stays signed in, outside links open in Safari

A new build (Actions > testflight > Run workflow) is only needed for native changes:
icon, name, permissions, a new native ability.

## How push works
The app hands Apple's device token to the page (`window.__nativePushToken`); the messenger's
`native-bridge.js` saves it via `POST /api/v1/push/subscribe` as an `apns:<token>` endpoint.
The server's `app/apns.py` sends to those endpoints; routing, dedup and retry are the same as web push.
Server needs `APNS_KEY_P8`, `APNS_KEY_ID` (and `APNS_TEAM_ID`, default 6JGS69NZ47) in `/opt/messenger/.env`.

## One-off setup (owner)
1. developer.apple.com > Identifiers > + App ID `au.com.strapify.messenger`, tick **Push Notifications**.
2. Keys > + key with **Apple Push Notifications service (APNs)** ticked; download the .p8 once.
   Its text + key id go in `/opt/messenger/.env` as `APNS_KEY_P8` / `APNS_KEY_ID`.
3. Profiles > + Distribution > App Store Connect, App ID above, the existing Apple Distribution
   certificate; name it exactly **Messenger App Store**.
4. App Store Connect > Apps > + New App, iOS, bundle `au.com.strapify.messenger`, SKU `strapify-messenger`;
   TestFlight > Internal Testing group with the testers.
5. Repo secrets: same six as Keywise + `PROFILE_APP` (base64 of the profile).
