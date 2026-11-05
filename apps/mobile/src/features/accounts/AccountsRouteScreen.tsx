import { useNavigation } from "@react-navigation/native";
import { Platform, ScrollView, View } from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";

import { AppBar } from "../../components/ui/AppBar";
import { NativeStackScreenOptions } from "../../native/StackHeader";
import { InfinitusAccounts } from "./InfinitusAccounts";

/** Settings › Accounts (#572). */
export function AccountsRouteScreen() {
  const navigation = useNavigation();
  const insets = useSafeAreaInsets();

  return (
    <View collapsable={false} className="flex-1 bg-sheet">
      {Platform.OS === "android" ? (
        <>
          <NativeStackScreenOptions options={{ headerShown: false }} />
          <AppBar embedded title="Accounts" onBack={() => navigation.goBack()} />
        </>
      ) : null}
      <ScrollView
        contentInsetAdjustmentBehavior="automatic"
        contentContainerClassName="p-5"
        contentContainerStyle={{ paddingBottom: insets.bottom + 24 }}
      >
        <InfinitusAccounts />
      </ScrollView>
    </View>
  );
}
