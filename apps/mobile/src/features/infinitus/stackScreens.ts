import {
  createNativeStackScreen,
  type NativeStackNavigationOptions,
} from "@react-navigation/native-stack";

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

/** The fork's new-task route, spread into the root stack beside upstream's
    `NewTaskProject` with the same header options: a native share can land in
    an existing thread instead of a new task. */
export function infinitusNewTaskScreens(headerOptions: NativeStackNavigationOptions) {
  return {
    NewTaskShareThread: createNativeStackScreen({
      screen: ShareToThreadRouteScreen,
      linking: "new/share/thread",
      options: { ...headerOptions, title: "Choose thread" },
    }),
  };
}
