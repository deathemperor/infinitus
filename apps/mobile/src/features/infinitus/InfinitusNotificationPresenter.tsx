import * as Notifications from "expo-notifications";
import { useEffect } from "react";
import { Platform } from "react-native";

import { presentInForeground } from "./notificationPresentation.logic";

const SHOW: Notifications.NotificationBehavior = {
  shouldShowBanner: true,
  shouldShowList: true,
  shouldPlaySound: false,
  shouldSetBadge: false,
};
const HIDE: Notifications.NotificationBehavior = {
  shouldShowBanner: false,
  shouldShowList: false,
  shouldPlaySound: false,
  shouldSetBadge: false,
};

/** Headless. The app's one foreground notification handler (#708): a Mac
    alert or an Infinitus alarm arriving while the app is open still shows as
    a banner (no sound — the user is looking at the phone); everything else
    gets the all-false behaviour iOS applies with no handler at all, so T3's
    agent notifications behave exactly as before. */
export function InfinitusNotificationPresenter() {
  useEffect(() => {
    if (Platform.OS === "web") return;
    Notifications.setNotificationHandler({
      handleNotification: async (notification) => (presentInForeground(notification) ? SHOW : HIDE),
    });
    return () => Notifications.setNotificationHandler(null);
  }, []);
  return null;
}
