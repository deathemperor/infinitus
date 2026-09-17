import * as Linking from "expo-linking";
import * as SplashScreen from "expo-splash-screen";
import { useEffect } from "react";
import { StatusBar, View } from "react-native";
import { GestureHandlerRootView } from "react-native-gesture-handler";
import { KeyboardProvider } from "react-native-keyboard-controller";
import { SafeAreaProvider } from "react-native-safe-area-context";
import { createStaticNavigation } from "@react-navigation/native";

import { RegistryContext } from "@effect/atom-react";
import {
  pairingUrlFromUniversalLink,
  UNIVERSAL_PAIR_HOST,
} from "./features/connection/universalPairLink.logic";
import { teamJoinLinkCode } from "./features/team/team.logic";
import { ThreadArrangementHost } from "./features/threads/ThreadArrangementSheet";
import { ConfirmDialogHost } from "./components/ConfirmDialogHost";
import { InfinitusAlarmsBridge } from "./features/infinitus/InfinitusAlarmsBridge";
import { InfinitusHoldsBridge } from "./features/infinitus/InfinitusHoldsBridge";
import { InfinitusNotificationPresenter } from "./features/infinitus/InfinitusNotificationPresenter";
import { CloudAuthProvider } from "./features/cloud/CloudAuthProvider";
import { prepareNativeShowcaseCapture } from "./features/showcase/nativeShowcaseScene";
import { IncomingShareProvider } from "./features/sharing/IncomingShareProvider";
import {
  AppearancePreferencesProvider,
  useAppearancePreferences,
} from "./features/settings/appearance/AppearancePreferencesProvider";
import { RootStack } from "./Stack";
import { appAtomRegistry } from "./state/atom-registry";
import { OverlayPortalHost } from "./components/OverlayPortal";
import { shouldHandleAppLink } from "./lib/appLinking";
import { useMobileNavigationTheme } from "./lib/useMobileNavigationTheme";
import { SubscriptionUsageCoordinator } from "./widgets/SubscriptionUsageCoordinator";

import "../global.css";

if (process.env.EXPO_PUBLIC_SHOWCASE === "1") {
  prepareNativeShowcaseCapture();
}

void SplashScreen.preventAutoHideAsync().catch(() => {
  // The native module can be unavailable in non-native test environments.
});

/** Fork (#724): a universal link from the Devices card
    (`https://infinitus.run/pair#token=…&to=<origin>`) becomes the
    add-environment route with the Mac's own pairing link, the same prefill a
    scanned QR takes (#746); any other URL passes through untouched. */
const rewriteIncomingUrl = (url: string | null): string | null => {
  if (url === null) return null;
  // #1313: a team invite (`https://infinitus.run/join#<code>`) opens Settings › Team with the code.
  const teamCode = teamJoinLinkCode(url);
  if (teamCode !== null) return Linking.createURL("team", { queryParams: { code: teamCode } });
  const pairingUrl = pairingUrlFromUniversalLink(url);
  return pairingUrl === null
    ? url
    : Linking.createURL("environment-new", { queryParams: { pairingUrl } });
};

const appLinking = {
  prefixes: [
    Linking.createURL("/"),
    "t3code://",
    "t3code-dev://",
    "t3code-preview://",
    // Fork (#724): the site's universal link, rewritten above before routing.
    `https://${UNIVERSAL_PAIR_HOST}`,
  ],
  getInitialURL: async () => rewriteIncomingUrl(await Linking.getInitialURL()),
  subscribe: (listener: (url: string) => void) => {
    const subscription = Linking.addEventListener("url", ({ url }) => {
      const rewritten = rewriteIncomingUrl(url);
      if (rewritten !== null) listener(rewritten);
    });
    return () => subscription.remove();
  },
  // Keep the compact thread list available beneath a directly opened thread.
  config: { initialRouteName: "Home" },
  filter: shouldHandleAppLink,
};

const Navigation = createStaticNavigation(RootStack);

function SplashScreenCoordinator() {
  const { isReady } = useAppearancePreferences();

  useEffect(() => {
    if (isReady) void SplashScreen.hide();
  }, [isReady]);

  return null;
}

export default function App() {
  return (
    <RegistryContext.Provider value={appAtomRegistry}>
      <CloudAuthProvider>
        <AppearancePreferencesProvider>
          <AppContent />
        </AppearancePreferencesProvider>
      </CloudAuthProvider>
    </RegistryContext.Provider>
  );
}

function AppContent() {
  const { themeAppearance } = useAppearancePreferences();
  const navigationTheme = useMobileNavigationTheme();

  return (
    <>
      <SplashScreenCoordinator />
      <SubscriptionUsageCoordinator />
      <GestureHandlerRootView className="flex-1">
        <KeyboardProvider statusBarTranslucent>
          <SafeAreaProvider>
            <StatusBar
              barStyle={themeAppearance === "dark" ? "light-content" : "dark-content"}
              translucent
            />
            {/* The navigation theme drives the NATIVE header appearance: native-stack
                forwards `dark` as the nav bar's overrideUserInterfaceStyle. Without
                this, React Navigation defaults to its light theme and every native
                header (glass buttons, title, materials) is forced light even when
                the system is in dark mode. */}
            <View style={{ flex: 1 }}>
              <IncomingShareProvider>
                <Navigation linking={appLinking} theme={navigationTheme} />
              </IncomingShareProvider>
              <ConfirmDialogHost />
              <ThreadArrangementHost />
<<<<<<< HEAD
              <InfinitusAlarmsBridge />
              <InfinitusHoldsBridge />
              <InfinitusNotificationPresenter />
            </BlurTargetView>
=======
            </View>
>>>>>>> upstream-sync-d4d5d12e8-upstream-renamed
            {/* Anchored-menu overlays render here — in-window, so the
                keyboard stays up while a dropdown is open. */}
            <OverlayPortalHost />
          </SafeAreaProvider>
        </KeyboardProvider>
      </GestureHandlerRootView>
    </>
  );
}
