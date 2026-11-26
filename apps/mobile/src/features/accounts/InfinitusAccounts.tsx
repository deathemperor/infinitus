import { useAtomValue } from "@effect/atom-react";
import type { EnvironmentId } from "@infinitus/contracts";
import { useMemo } from "react";
import { Linking, View } from "react-native";

import { AppText as Text } from "../../components/ui/AppText";
import { EmptyState } from "../../components/ui/EmptyState";
import { ErrorBanner } from "../../components/ui/ErrorBanner";
import { ProviderIcon } from "../../components/ProviderIcon";
import { cn } from "../../lib/cn";
import { infinitusEnvironment } from "../../state/infinitus";
import { environmentPresentations } from "../../state/presentation";
import { useEnvironmentQuery } from "../../state/query";
import { environmentServerConfigsAtom } from "../../state/server";
import { InfinitusSignIns } from "../infinitus/InfinitusSignIns";
import { SettingsSection } from "../settings/components/SettingsSection";
import { AccountRow } from "./AccountRow";
import {
  fleetSignsInFromPhone,
  type InfinitusMac,
  infinitusMacs,
  macAccountsModel,
} from "./accountsRoute.logic";
import { ExhaustedBand } from "./ExhaustedBand";
import { FleetSignInPanel } from "./FleetSignInPanel";
import { ForecastStrip } from "./ForecastStrip";
import { useFleetSignIn } from "./useFleetSignIn";
import { useNowMinute } from "./useNowMinute";
import { PRODUCT_NAME } from "@infinitus/shared/productName";
import { snapshotSignInRunning } from "@infinitus/client-runtime/state/infinitusAccounts";
import { signInBusy } from "@infinitus/client-runtime/state/infinitusSignIn";

/** A fleet's provider as the driver `ProviderIcon` draws. Only the two it has
    a mark for: it draws anything else with the Codex mark. */
const FLEET_PROVIDER_DRIVER: Readonly<Record<string, string>> = {
  claude: "claudeAgent",
  codex: "codex",
};

/** Every paired Mac that runs Infinitus, its fleets and their accounts (#572), read and driven
    through the T3 server's adapter. Settings › Accounts and the Usage screen's Accounts tab. */
export function InfinitusAccounts(props: {
  /** The Usage screen's environment filter; null shows every Mac. */
  readonly environmentIds?: ReadonlySet<EnvironmentId> | null;
}) {
  const configs = useAtomValue(environmentServerConfigsAtom);
  const presentations = useAtomValue(environmentPresentations.presentationsAtom);
  const { environmentIds = null } = props;
  const macs = useMemo(
    () =>
      infinitusMacs(configs, presentations).filter(
        (mac) => environmentIds === null || environmentIds.has(mac.environmentId),
      ),
    [configs, presentations, environmentIds],
  );

  return (
    <View className="gap-5">
      {macs.length > 0 ? <InfinitusSignIns environmentIds={environmentIds} /> : null}
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
          Add account and Sign in again run the provider's sign-in from this phone; the account is
          stored on that Mac. Engines are set up in Infinitus on the Mac.
        </Text>
      ) : null}
    </View>
  );
}

function MacAccounts(props: { readonly mac: InfinitusMac; readonly titled: boolean }) {
  const { mac } = props;
  const view = useEnvironmentQuery(
    infinitusEnvironment.snapshot({ environmentId: mac.environmentId, input: {} }),
  );
  const now = useNowMinute();
  const model = macAccountsModel(view.data, now);
  const signIn = useFleetSignIn(mac.environmentId);
  const signInRunning =
    signInBusy(signIn.flow) || (view.data !== null && snapshotSignInRunning(view.data));
  return (
    <View className="gap-3">
      {props.titled ? (
        <Text className="px-2 text-sm font-infinitus-medium text-foreground-muted">
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
        // #869: the socket answered and no engine reports a fleet — the
        // web's copy (#934); the phone has no Engines pane, so it points at
        // the desktop app's.
        <EmptyState
          title="Infinitus is running, but no engine reports accounts"
          detail="swapd ships with Infinitus: turn it on in the desktop app on that Mac, under Settings › Engines, then add the first account from its Accounts page."
          actionLabel="Read the accounts setup guide"
          onAction={() =>
            void Linking.openURL(
              "https://github.com/deathemperor/infinitus/blob/main/docs/user/accounts.md",
            )
          }
        />
      ) : null}
      {model.sections.map((section) => {
        const signsIn = view.data !== null && fleetSignsInFromPhone(view.data, section);
        return (
          <SettingsSection
            key={section.key}
            title={section.title}
            trailing={
              FLEET_PROVIDER_DRIVER[section.provider] === undefined ? null : (
                <View className="px-2">
                  <ProviderIcon provider={FLEET_PROVIDER_DRIVER[section.provider]} size={14} />
                </View>
              )
            }
          >
            {model.bands.has(section.key) ? (
              <ExhaustedBand band={model.bands.get(section.key)!} nowMs={now} />
            ) : null}
            {section.rows.map((row, index) => (
              <AccountRow
                key={row.number}
                environmentId={mac.environmentId}
                fleetKey={section.key}
                fleetTitle={section.title}
                row={row}
                last={index === section.rows.length - 1 && section.caveat === null && !signsIn}
                onRelogin={
                  signsIn && row.reloginNeeded
                    ? () => void signIn.start(section.key, row)
                    : undefined
                }
                reloginBusy={signInRunning}
              />
            ))}
            {section.caveat ? (
              <Text
                className={cn(
                  "px-4 py-3 text-xs text-foreground-muted",
                  signsIn && "border-b border-separator",
                )}
              >
                {section.caveat}
              </Text>
            ) : null}
            {signsIn ? (
              <FleetSignInPanel
                fleetTitle={section.title}
                flow={signIn.flow?.fleetKey === section.key ? signIn.flow : null}
                busy={signInRunning}
                empty={section.rows.length === 0}
                onAdd={() => void signIn.start(section.key, null)}
                onCancel={() => void signIn.cancel()}
                onReopen={signIn.reopen}
                onSubmit={(text) => void signIn.submit(text)}
              />
            ) : null}
          </SettingsSection>
        );
      })}
      {model.forecast ? <ForecastStrip forecast={model.forecast} /> : null}
    </View>
  );
}
