import {
  createNativeStackScreen,
  type NativeStackNavigationOptions,
} from "@react-navigation/native-stack";

import { AccountsRouteScreen } from "../accounts/AccountsRouteScreen";
import { ShareToThreadRouteScreen } from "../sharing/ShareToThreadRouteScreen";
import { TeamRouteScreen } from "../team/TeamRouteScreen";

/** The fork's Settings routes, spread into `Stack.tsx`'s root `SETTINGS_SCREENS` with
    upstream's settings page options: Settings › Accounts (the Infinitus fleet per paired
    Mac) and Settings › Team (`settings/team?code=…` is where an invite link lands,
    `appLinking.ts`). */
export function infinitusSettingsScreens(pageOptions: NativeStackNavigationOptions) {
  return {
    SettingsAccounts: createNativeStackScreen({
      screen: AccountsRouteScreen,
      linking: "settings/accounts",
      options: { ...pageOptions, title: "Accounts" },
    }),
    SettingsTeam: createNativeStackScreen({
      screen: TeamRouteScreen,
      linking: "settings/team",
      options: { ...pageOptions, title: "Team" },
    }),
  };
}

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
