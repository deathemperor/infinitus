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

/** Headless. The foreground notification handler (#708): an Infinitus account alert or
    alarm shows as a banner without sound; everything else gets the all-false behaviour
    iOS applies with no handler, so T3's notifications are unchanged. */
export function InfinitusNotificationPresenter() {
  // oxlint-disable-next-line t3code/no-unreasoned-state-sync -- installs the expo-notifications foreground handler while mounted
  useEffect(() => {
    if (Platform.OS === "web") return;
    Notifications.setNotificationHandler({
      handleNotification: async (notification) => (presentInForeground(notification) ? SHOW : HIDE),
    });
    return () => Notifications.setNotificationHandler(null);
  }, []);
  return null;
}
