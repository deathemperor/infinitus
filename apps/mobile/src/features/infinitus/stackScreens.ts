import { createNativeStackScreen } from "@react-navigation/native-stack";

import { AccountsRouteScreen } from "../accounts/AccountsRouteScreen";
import { ShareToThreadRouteScreen } from "../sharing/ShareToThreadRouteScreen";
import { TeamRouteScreen } from "../team/TeamRouteScreen";

/** The fork's Settings routes, spread into `Stack.tsx`'s settings stack:
    Settings › Accounts (the Infinitus fleet per paired Mac) and Settings ›
    Team (#1313; `team?code=…` is where an invite link lands, `appLinking.ts`). */
export const INFINITUS_SETTINGS_SCREENS = {
  SettingsAccounts: createNativeStackScreen({
    screen: AccountsRouteScreen,
    linking: "accounts",
    options: {
      title: "Accounts",
    },
  }),
  SettingsTeam: createNativeStackScreen({
    screen: TeamRouteScreen,
    linking: "team",
    options: {
      title: "Team",
    },
  }),
};

/** The fork's new-task sheet route, spread the same way: a native share can
    land in an existing thread instead of a new task. */
export const INFINITUS_NEW_TASK_SCREENS = {
  NewTaskShareThread: createNativeStackScreen({
    screen: ShareToThreadRouteScreen,
    linking: "share/thread",
    options: {
      title: "Choose thread",
    },
  }),
};
