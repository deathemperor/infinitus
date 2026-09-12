import { View } from "react-native";

import { SymbolView } from "../../components/AppSymbol";
import { AppText as Text } from "../../components/AppText";

/**
 * Fork (#832): the quiet amber line under the thread's banners while the
 * server waits to reopen a turn whose transport went away — the web's
 * `ThreadReconnectingNotice`. Not an error: the turn is still running.
 */
export function InfinitusReconnectingNotice(props: { readonly notice: string }) {
  return (
    <View
      accessibilityRole="text"
      className="flex-row items-center gap-3 rounded-[20px] border border-warning-border bg-warning px-4 py-3"
    >
      <SymbolView name="wifi.slash" size={18} tintColorClassName="accent-warning-foreground" />
      <Text className="flex-1 font-sans text-sm leading-normal text-warning-foreground">
        {props.notice}
      </Text>
    </View>
  );
}
