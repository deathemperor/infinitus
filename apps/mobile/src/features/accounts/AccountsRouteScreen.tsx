import { useAtomValue } from "@effect/atom-react";
import { StackActions, useNavigation } from "@react-navigation/native";
import { useEffect, useMemo, useState } from "react";
import { Platform, ScrollView, View } from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";

import { AndroidScreenHeader } from "../../components/AndroidScreenHeader";
import { AppText as Text } from "../../components/AppText";
import { EmptyState } from "../../components/EmptyState";
import { ErrorBanner } from "../../components/ErrorBanner";
import { NativeStackScreenOptions } from "../../native/StackHeader";
import { infinitusEnvironment } from "../../state/infinitus";
import { environmentPresentations } from "../../state/presentation";
import { useEnvironmentQuery } from "../../state/query";
import { environmentServerConfigsAtom } from "../../state/server";
import { InfinitusSignIns } from "../infinitus/InfinitusSignIns";
import { InfinitusSessions } from "../infinitus/InfinitusSessions";
import { macSessionsView } from "../infinitus/sessions.logic";
import { SettingsSection } from "../settings/components/SettingsSection";
import { AccountRow } from "./AccountRow";
import { type InfinitusMac, infinitusMacs, macAccountsModel } from "./accountsRoute.logic";
import { ForecastStrip } from "./ForecastStrip";
import { PRODUCT_NAME } from "@t3tools/shared/productName";

/** Settings › Accounts (#572): every paired Mac that runs Infinitus, its fleets
    and their accounts, read and driven through the T3 server's adapter. */
export function AccountsRouteScreen() {
  const navigation = useNavigation();
  const insets = useSafeAreaInsets();
  const configs = useAtomValue(environmentServerConfigsAtom);
  const presentations = useAtomValue(environmentPresentations.presentationsAtom);
  const macs = useMemo(() => infinitusMacs(configs, presentations), [configs, presentations]);

  return (
    <View collapsable={false} className="flex-1 bg-sheet">
      {Platform.OS === "android" ? (
        <>
          <NativeStackScreenOptions options={{ headerShown: false }} />
          <AndroidScreenHeader title="Accounts" onBack={() => navigation.goBack()} />
        </>
      ) : null}
      <ScrollView
        contentInsetAdjustmentBehavior="automatic"
        contentContainerClassName="gap-5 p-5"
        contentContainerStyle={{ paddingBottom: insets.bottom + 24 }}
      >
        {macs.length > 0 ? <InfinitusSignIns /> : null}
        {macs.length === 0 ? (
          <EmptyState
            title="No Infinitus Mac"
            detail={`Accounts appear here once a paired Mac's ${PRODUCT_NAME} server runs beside the Infinitus menu bar app. Plain servers have nothing to show.`}
          />
        ) : (
          macs.map((mac) => (
            <MacAccounts key={mac.environmentId} mac={mac} titled={macs.length > 1} />
          ))
        )}
        {macs.length > 0 ? (
          <Text className="px-2 text-xs text-foreground-tertiary">
            Accounts are added and removed in Infinitus on the Mac.
          </Text>
        ) : null}
      </ScrollView>
    </View>
  );
}

/** A minute clock for the session ages: read once on mount, then each minute. */
function useNowMinute(): number {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const id = setInterval(() => setNow(Date.now()), 60_000);
    return () => clearInterval(id);
  }, []);
  return now;
}

function MacAccounts(props: { readonly mac: InfinitusMac; readonly titled: boolean }) {
  const { mac } = props;
  const navigation = useNavigation();
  const view = useEnvironmentQuery(
    infinitusEnvironment.snapshot({ environmentId: mac.environmentId, input: {} }),
  );
  const model = macAccountsModel(view.data);
  const now = useNowMinute();
  const sessions = macSessionsView(view.data, now);
  return (
    <View className="gap-3">
      {props.titled ? (
        <Text className="px-2 text-sm font-t3-medium text-foreground-muted">
          {mac.connected ? mac.label : `${mac.label} · disconnected`}
        </Text>
      ) : null}
      {view.error ? <ErrorBanner message={view.error} /> : null}
      {model.state === "loading" && view.error === null ? (
        <Text className="px-2 text-sm text-foreground-muted">Reading the fleet…</Text>
      ) : null}
      {model.state === "unavailable" ? (
        <EmptyState
          title="Infinitus is not answering"
          detail={model.unavailableReason ?? "The app is not running on this Mac."}
          actionLabel="Retry"
          onAction={view.refresh}
        />
      ) : null}
      {model.state === "empty" ? (
        <EmptyState title="No accounts yet" detail="Add accounts in Infinitus on the Mac." />
      ) : null}
      {model.sections.map((section) => (
        <SettingsSection key={section.key} title={section.title} card>
          {section.rows.map((row, index) => (
            <AccountRow
              key={row.number}
              environmentId={mac.environmentId}
              fleetKey={section.key}
              fleetTitle={section.title}
              row={row}
              last={index === section.rows.length - 1 && section.caveat === null}
            />
          ))}
          {section.caveat ? (
            <Text className="px-4 py-3 text-xs text-foreground-muted">{section.caveat}</Text>
          ) : null}
        </SettingsSection>
      ))}
      {model.forecast ? <ForecastStrip forecast={model.forecast} /> : null}
      {sessions ? (
        <InfinitusSessions
          environmentId={mac.environmentId}
          view={sessions}
          // The settings sheet route itself becomes the thread (the new-task
          // draft leaves its sheet the same way), so nothing stacks on the sheet.
          onOpenThread={(threadId) =>
            (navigation.getParent() ?? navigation).dispatch(
              StackActions.replace("Thread", {
                environmentId: String(mac.environmentId),
                threadId: String(threadId),
              }),
            )
          }
        />
      ) : null}
    </View>
  );
}
