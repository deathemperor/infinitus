# Mobile notifications

Get push alerts, Live Activities, and home-screen widgets on iOS and Android when agents finish, fail, or need your approval or input.

## Prerequisites

- Sign in to **Infinitus Connect** on both your phone and host machine (direct/Tailscale connections alone do not deliver background push notifications).
- Enable **Publish agent activity** in **Settings → Sharing & access** on the host.
- Enable **Device Notifications** in **Settings → Notifications** on mobile (Android requires Android 7.0+ and Google Play services).

## Live updates and widgets

- **Live progress**: Enable **Live Activity Updates** (iOS), **Agent Live Updates** (Android 16+, check **Live Update Settings** if missing), or **Ongoing Agent Activity** (older Android). Finished results stay visible for up to 15 minutes.
- **Silent live updates (Android 8+)**: Keep **Ongoing agent activity** on and disable **Agent alerts** in Android system notification settings.
- **iOS widget**: Add the **Agent Activity** widget to your Home Screen or Lock Screen (refreshes when you open Infinitus; marks unfinished work stale after 10 minutes).

## Notes

<<<<<<< HEAD
Notification permission and Android notification channels are controlled in system Settings. Background delivery requires Infinitus Connect; a direct or Tailscale connection alone does not enable push notifications. The mobile app does not need to maintain a connection to your environment. Force-stopping the Android app in system Settings prevents push delivery until you open it again.

## Alerts from an Infinitus Mac

A paired Infinitus Mac's own alerts (an account switch, every account exhausted, a sign-in that lapsed) reach your phone the same way an agent's do: through Infinitus Connect, under **Device Notifications**, with nothing to set up on the Mac. Tap one to open **Settings → Accounts**. The lock-screen thread card on an iPhone is the same **Live Activity Updates** card described above; there is no separate Mac card. **Settings → Infinitus → Devices** on the Mac's server is where you name the Mac, approve a phone that asked to pair, and sync its settings over iCloud Drive; pairing links are created under **Settings → Connections**.
=======
- Ordinary alerts are muted while the mobile app is in the foreground, though viewing a thread on another device does not silence your phone.
- Force-stopping Infinitus in Android system Settings pauses push delivery until you reopen the app.
>>>>>>> upstream-sync-d878f7b192-upstream-renamed
