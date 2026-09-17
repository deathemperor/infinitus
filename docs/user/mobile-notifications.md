# Mobile notifications

Sign in to Infinitus Connect, link your environments, and enable **Device Notifications** in Settings to receive alerts when an agent finishes, fails, needs approval, or asks for input. Tap a notification to open its thread. Your environment must have agent activity publishing enabled.

Enable **Ongoing Agent Activity** on Android or **Live Activity Updates** on iOS to follow work without opening the app. Finished results remain visible for up to 15 minutes. You can dismiss an Android activity card without disabling alerts; turn off ongoing activity in Settings to stop future cards.

Ordinary alerts stay quiet while the mobile app is in the foreground. Ongoing activity continues to update. Viewing a thread on another device does not silence your phone's alerts.

Android notifications require Android 7.0 or newer and Google Play services. Android 16 and newer can promote ongoing activity to a Live Update, subject to system settings and device support. Other devices show a regular ongoing notification. Android 7's battery-saving modes can delay removal of expired cards.

Notification permission and Android notification channels are controlled in system Settings. Background delivery requires Infinitus Connect; a direct or Tailscale connection alone does not enable push notifications. The mobile app does not need to maintain a connection to your environment. Force-stopping the Android app in system Settings prevents push delivery until you open it again.

## Alerts from an Infinitus Mac

A paired Infinitus Mac's own alerts (an account switch, every account exhausted, a sign-in that lapsed) reach your phone the same way an agent's do: through Infinitus Connect, under **Device Notifications**, with nothing to set up on the Mac. Tap one to open **Settings → Accounts**. The lock-screen thread card on an iPhone is the same **Live Activity Updates** card described above; there is no separate Mac card. **Settings → Infinitus → Devices** on the Mac's server is where you name the Mac, approve a phone that asked to pair, and sync its settings over iCloud Drive; pairing links are created under **Settings → Connections**.
