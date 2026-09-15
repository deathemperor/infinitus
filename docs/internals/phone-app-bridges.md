# Phone app links and bridges

## The universal pair link

`apps/mobile/src/App.tsx` — `appLinking` rewrites an incoming universal link `https://infinitus.run/pair#token=…&for=phone&to=<origin>` into the `environment-new?pairingUrl=<origin>/pair#…` route (`getInitialURL` / `subscribe`, `features/connection/universalPairLink.logic.ts`, #724): the Mac's origin travels in the fragment the site never sees, `to` is taken as a bare http(s) origin only, and the sheet fills Host and code like a scanned QR (#746) — the same rewrite runs on the in-app scanner's payload and on the route's `pairingUrl`.

## The bridges

Mounts `InfinitusAlarmsBridge` (local reset / swap alarms), `InfinitusAlertPushBridge` (the `alert` token, so the Mac's pushes reach the phone as banners; it withdraws the kind with `activities-token --forget <deviceId>/<kind>` through `pushForget.ts` / `pushForget.logic.ts` when its switch goes off, #702), `InfinitusThreadCardBridge` (the lock-screen thread card's tokens, #1047: the push-to-start token as `agent-activity-start` and each running `AgentActivity` card's own token as `agent-activity`, re-read on every foreground and after a local start; both withdrawn the same way when the switch goes off) and `InfinitusNotificationPresenter` (the app's one foreground notification handler: Infinitus notifications show as banners in-app, T3's keep the no-handler default), and `InfinitusHoldsBridge` (#1278 finding 7: one `subscribeInfinitusHolds` subscription per Infinitus Mac for the app's lifetime, so the outbox drain's registry read of the holds atom sees a delivered list instead of mounting the stream itself and reading null on the first queued message).
