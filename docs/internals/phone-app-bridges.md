# Phone app links and bridges

## The universal pair link

`apps/mobile/src/App.tsx` — `appLinking` rewrites an incoming universal link `https://infinitus.run/pair#token=…&for=phone&to=<origin>` into the `environment-new?pairingUrl=<origin>/pair#…` route (`getInitialURL` / `subscribe`, `features/connection/universalPairLink.logic.ts`, #724): the Mac's origin travels in the fragment the site never sees, `to` is taken as a bare http(s) origin only, and the sheet fills Host and code like a scanned QR (#746) — the same rewrite runs on the in-app scanner's payload and on the route's `pairingUrl`.

## The bridges

Mounts `InfinitusAlarmsBridge` (local reset / swap alarms), `InfinitusNotificationPresenter` (the app's one foreground notification handler: an Infinitus account alert — the relay's push whose deep link is Settings › Accounts, #1375 — and the alarms show as banners in-app, T3's keep the no-handler default) and `InfinitusHoldsBridge` (#1278 finding 7: one `subscribeInfinitusHolds` subscription per Infinitus Mac for the app's lifetime, so the outbox drain's registry read of the holds atom sees a delivered list instead of mounting the stream itself and reading null on the first queued message). The Mac-push bridges (`InfinitusAlertPushBridge` #702, `InfinitusThreadCardBridge` #1047) left with #1375: a Mac's account alerts go Mac → desktop server → Infinitus Connect → phone, and the lock-screen thread card is the relay's own.
