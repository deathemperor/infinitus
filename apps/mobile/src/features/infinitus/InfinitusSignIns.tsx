import { useAtomValue } from "@effect/atom-react";
import { useMemo, useState } from "react";
import { Linking, Pressable, View } from "react-native";

import { AppText as Text } from "../../components/AppText";
import { cn } from "../../lib/cn";
import { infinitusEnvironment } from "../../state/infinitus";
import { environmentPresentations } from "../../state/presentation";
import { useEnvironmentQuery } from "../../state/query";
import { environmentServerConfigsAtom } from "../../state/server";
import { useAtomCommand } from "../../state/use-atom-command";
import {
  commandFailureMessage,
  type InfinitusMac,
  infinitusMacs,
} from "../accounts/accountsRoute.logic";
import {
  lapsedSignIns,
  type SignInModel,
  signInHeadline,
  startSignInCommand,
} from "./signIns.logic";

/** Every paired Mac's lapsed AWS / gcloud sign-ins as cards (#572 task 7):
    on Home above the thread list, and in Settings › Accounts. Renders
    nothing when no Mac reports one. */
export function InfinitusSignIns(props: { readonly className?: string }) {
  const configs = useAtomValue(environmentServerConfigsAtom);
  const presentations = useAtomValue(environmentPresentations.presentationsAtom);
  const macs = useMemo(() => infinitusMacs(configs, presentations), [configs, presentations]);
  if (macs.length === 0) return null;
  return (
    <View className={cn("gap-3", props.className)}>
      {macs.map((mac) => (
        <MacSignIns key={mac.environmentId} mac={mac} />
      ))}
    </View>
  );
}

function MacSignIns(props: { readonly mac: InfinitusMac }) {
  const view = useEnvironmentQuery(
    infinitusEnvironment.snapshot({ environmentId: props.mac.environmentId, input: {} }),
  );
  const items = lapsedSignIns(view.data);
  if (items.length === 0) return null;
  return (
    <>
      {items.map((item) => (
        <SignInCard key={item.key} mac={props.mac} item={item} />
      ))}
    </>
  );
}

function SignInCard(props: { readonly mac: InfinitusMac; readonly item: SignInModel }) {
  const { mac, item } = props;
  const run = useAtomCommand(infinitusEnvironment.command, { reportFailure: false });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const start = async () => {
    setBusy(true);
    setError(null);
    const result = await run({ environmentId: mac.environmentId, input: startSignInCommand(item) });
    setBusy(false);
    if (result._tag !== "Success") setError(commandFailureMessage(result.cause));
  };

  return (
    <View className="gap-2 rounded-[22px] border border-warning-border bg-warning p-4">
      <Text className="text-sm font-t3-medium text-warning-foreground">{signInHeadline(item)}</Text>
      <Text className="text-xs text-warning-foreground">
        {item.phase === "starting"
          ? `${mac.label} is starting the sign-in…`
          : item.phase === "waiting" && item.url
            ? "Open the sign-in page; the Mac finishes by itself once you approve."
            : item.phase === "waiting"
              ? `${mac.label} is waiting for the sign-in to finish in its browser.`
              : item.phase === "failed"
                ? (item.message ?? "The last sign-in failed.")
                : `Sign in on ${mac.label} to let the session continue.`}
      </Text>
      {item.userCode ? (
        <Text selectable className="text-lg font-t3-bold tabular-nums text-warning-foreground">
          {item.userCode}
        </Text>
      ) : null}
      <View className="flex-row flex-wrap items-center gap-2">
        {item.url ? (
          <Pressable
            accessibilityRole="button"
            onPress={() => void Linking.openURL(item.url ?? "")}
            className="rounded-full bg-primary px-4 py-2 active:opacity-70"
          >
            <Text className="text-sm font-t3-bold text-primary-foreground">Open sign-in page</Text>
          </Pressable>
        ) : null}
        {item.phase === "idle" || item.phase === "failed" ? (
          <Pressable
            accessibilityRole="button"
            disabled={busy}
            onPress={() => void start()}
            className={cn(
              "rounded-full px-4 py-2 active:opacity-70",
              item.url ? "bg-subtle" : "bg-primary",
            )}
          >
            <Text
              className={cn(
                "text-sm font-t3-bold",
                item.url ? "text-foreground" : "text-primary-foreground",
              )}
            >
              {busy
                ? "Starting…"
                : item.phase === "failed"
                  ? "Try again on the Mac"
                  : `Sign in on ${mac.label}`}
            </Text>
          </Pressable>
        ) : null}
      </View>
      {error ? <Text className="text-xs text-danger-foreground">{error}</Text> : null}
    </View>
  );
}
