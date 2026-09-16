# Mobile notifications

Sign in to Infinitus Connect, link your environments, and enable **Device Notifications** in Settings to receive alerts when an agent finishes, fails, needs approval, or asks for input. Tap a notification to open its thread. Your environment must have agent activity publishing enabled.

Enable **Ongoing Agent Activity** on Android or **Live Activity Updates** on iOS to follow work without opening the app. Finished results remain visible for up to 15 minutes. You can dismiss an Android activity card without disabling alerts; turn off ongoing activity in Settings to stop future cards.

Ordinary alerts stay quiet while the mobile app is in the foreground. Ongoing activity continues to update. Viewing a thread on another device does not silence your phone's alerts.

Android notifications require Android 7.0 or newer and Google Play services. Android 16 and newer can promote ongoing activity to a Live Update, subject to system settings and device support. Other devices show a regular ongoing notification. Android 7's battery-saving modes can delay removal of expired cards.

Notification permission and Android notification channels are controlled in system Settings. Background delivery requires Infinitus Connect; a direct or Tailscale connection alone does not enable push notifications. The mobile app does not need to maintain a connection to your environment. Force-stopping the Android app in system Settings prevents push delivery until you open it again.

## Alerts from an Infinitus Mac

A paired Infinitus Mac can also push its own alerts (an account switch, every account exhausted) to the phone while the app is closed. In **Settings → Infinitus → Devices**, enter the **Team ID** and **Key ID** of an Apple Push Notifications key from your developer account, then upload the `.p8` under **Push key**. The key stays in that Mac's keychain; **Forget key** removes it. The same page lists the phones registered for pushes and lets you name the Mac and sync its settings over iCloud Drive.

On an iPhone the Mac can also keep a **lock-screen thread card** going while the app is closed: one Live Activity showing what your threads are doing, updated over push. It is on by default; turn it off with **Thread card on the lock screen** in the phone's **Settings → Infinitus**. Live Activities must be allowed for Infinitus in the phone's own Settings. **Show a test card** starts a card on the phone alone, with no Mac involved, so you can tell a phone that cannot draw the card from a Mac that never reached it; press it again to end the card. **Card push registration** on the same page says where the card stands and, when tapped, what to check: **Registered** means the Mac can start a card on its own, **No token yet** that the phone is waiting on iOS, **Refused** or **Mac unreachable** that the Mac declined or could not be reached (the phone tries again once it can), and while the switch is off, **Off, withdrawn** that the Mac dropped the phone's card tokens. Android phones have no Live Activities, so the card and its rows do not apply there.
