# Mobile notifications

Sign in to Infinitus Connect, link your environments, and enable **Device Notifications** in **Settings → Notifications** to receive alerts when an agent finishes, fails, needs approval, or asks for input. Tap a notification to open its thread. Your environment must have agent activity publishing enabled.

Enable **Live Activity Updates** on iOS, **Agent Live Updates** on Android 16 and newer, or **Ongoing Agent Activity** on older Android versions to follow work without opening the app. Finished results remain visible for up to 15 minutes. You can dismiss an Android activity card without disabling alerts; turn off the same switch to stop future cards.

For activity without ordinary alerts on Android 8 or newer, leave **Ongoing agent activity** enabled and turn off **Agent alerts** in Android's notification settings for Infinitus. Activity updates continue, and the same card shows the finished result without a separate alert. On Android 16 and newer, the finished result remains a Live Update until dismissed or expired. Keep app-wide notification permission and **Live updates** enabled so Android can display it.

On iOS you can also add the **Agent Activity** widget to your Home Screen or Lock Screen. It shows the same agents as the Live Activity, using your Infinitus Connect sign-in. The widget refreshes when you open Infinitus and shows unfinished work as out of date after 10 minutes.

Ordinary alerts stay quiet while the mobile app is in the foreground. Ongoing activity continues to update. Viewing a thread on another device does not silence your phone's alerts.

Android notifications require Android 7.0 or newer and Google Play services. Android 16 and newer can promote ongoing activity to a Live Update, subject to system settings and device support. Other devices show a regular ongoing notification. If Live Updates don't appear on Android 16 or newer, check **Live Update Settings** in Infinitus's **Settings → Notifications**. Android 7's battery-saving modes can delay removal of expired cards.

Notification permission and Android notification channels are controlled in system Settings. Background delivery requires Infinitus Connect; a direct or Tailscale connection alone does not enable push notifications. The mobile app does not need to maintain a connection to your environment. Force-stopping the Android app in system Settings prevents push delivery until you open it again.

## Alerts from an Infinitus Mac

A paired Infinitus Mac's own alerts (an account switch, every account exhausted, a sign-in that lapsed) reach your phone the same way an agent's do: through Infinitus Connect, under **Device Notifications**, with nothing to set up on the Mac. Tap one to open **Settings → Accounts**. The lock-screen thread card on an iPhone is the same **Live Activity Updates** card described above; there is no separate Mac card. **Settings → Infinitus → Devices** on the Mac's server is where you name the Mac, approve a phone that asked to pair, and sync its settings over iCloud Drive; pairing links are created under **Settings → Connections**.
