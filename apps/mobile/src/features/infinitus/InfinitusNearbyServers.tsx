import * as Network from "expo-network";
import { useCallback, useEffect, useRef, useState } from "react";
import { ActivityIndicator, Pressable, View } from "react-native";

import { AppText as Text } from "../../components/AppText";
import { ConnectionSheetButton } from "../connection/ConnectionSheetButton";
import { discoverNearbyServers } from "./lanDiscovery";
import {
  type NearbyServer,
  type SweepReport,
  networkWord,
  shouldRetrySweep,
  SWEEP_RETRY_DELAY_MS,
  sweepSummary,
} from "./lanDiscovery.logic";

/** Sweeps started since the app opened; the first one may run before the
    Local Network grant lands and gets one automatic retry (#787). */
let sweepsThisSession = 0;

const wait = (ms: number, signal: AbortSignal) =>
  new Promise<void>((resolve) => {
    const timer = setTimeout(resolve, ms);
    signal.addEventListener(
      "abort",
      () => {
        clearTimeout(timer);
        resolve();
      },
      { once: true },
    );
  });

type Phase = "idle" | "scanning" | "done";

/**
 * "Find Macs on this network" on the add-connection form (#651): sweeps the
 * phone's Wi‑Fi for desktop servers and fills the Host field with a tap — the
 * server's own LAN address when it reports one (#757). The one-time code from
 * the Mac's Devices card is still typed by hand; the form says so after a pick.
 */
export function InfinitusNearbyServers(props: { readonly onPick: (host: string) => void }) {
  const [phase, setPhase] = useState<Phase>("idle");
  const [found, setFound] = useState<ReadonlyArray<NearbyServer>>([]);
  const [notice, setNotice] = useState<string | null>(null);
  /** The last sweep's line (#787): what was swept, from where, how it went. */
  const [report, setReport] = useState<SweepReport | null>(null);
  const scan = useRef<AbortController | null>(null);

  useEffect(() => () => scan.current?.abort(), []);

  const start = useCallback(async () => {
    scan.current?.abort();
    const controller = new AbortController();
    scan.current = controller;
    setPhase("scanning");
    setFound([]);
    setNotice(null);
    setReport(null);
    let ownIp: string | null = null;
    try {
      ownIp = await Network.getIpAddressAsync();
    } catch {
      ownIp = null;
    }
    if (ownIp === "0.0.0.0") ownIp = null;
    let network: string | null = null;
    try {
      network = networkWord((await Network.getNetworkStateAsync()).type);
    } catch {
      network = null;
    }
    if (ownIp === null) setNotice("Join the Mac's Wi‑Fi first.");
    const firstSweepOfSession = sweepsThisSession === 0;
    sweepsThisSession += 1;
    const sweep = () =>
      discoverNearbyServers({
        ownIp,
        network,
        signal: controller.signal,
        onFound: (server) =>
          setFound((current) =>
            // One row per server: a Mac on two interfaces answers twice.
            current.some((item) => item.environmentId === server.environmentId)
              ? current
              : [...current, server],
          ),
      });
    let swept = await sweep();
    if (controller.signal.aborted) return;
    // #787: the session's first sweep can predate the Local Network grant;
    // a silent one is tried once more before the page says nobody answered.
    if (shouldRetrySweep({ report: swept, firstSweepOfSession })) {
      setNotice("Nothing answered on the first pass; looking once more…");
      await wait(SWEEP_RETRY_DELAY_MS, controller.signal);
      if (controller.signal.aborted) return;
      swept = { ...(await sweep()), retried: true };
      if (controller.signal.aborted) return;
      setNotice(null);
    }
    setReport(swept);
    setPhase("done");
  }, []);

  return (
    <View collapsable={false} className="gap-2">
      <ConnectionSheetButton
        icon="magnifyingglass"
        label={phase === "scanning" ? "Looking on this network…" : "Find Macs on this network"}
        disabled={phase === "scanning"}
        tone="secondary"
        onPress={() => {
          void start();
        }}
      />
      {phase === "scanning" ? (
        <View className="flex-row items-center gap-2 px-1">
          <ActivityIndicator colorClassName="accent-icon" size="small" />
          <Text className="text-xs text-foreground-muted">
            Trying every address on your Wi‑Fi; a few seconds.
          </Text>
        </View>
      ) : null}
      {found.map((server) => (
        <Pressable
          key={server.environmentId}
          accessibilityRole="button"
          onPress={() => props.onPick(server.host)}
          className="flex-row items-center justify-between rounded-[14px] border border-input-border bg-input px-4 py-3 active:opacity-70"
        >
          <View className="shrink gap-0.5">
            <Text className="text-base text-foreground">{server.label}</Text>
            <Text className="text-xs text-foreground-muted">
              {server.infinitus ? `Infinitus · ${server.host}` : server.host}
            </Text>
          </View>
          <Text className="text-xs font-t3-bold text-foreground-muted">Use</Text>
        </Pressable>
      ))}
      {phase === "done" && found.length === 0 ? (
        <Text className="text-xs text-foreground-muted">
          {notice ??
            "No Mac answered. On the Mac, turn on Network access under Settings › Connections, or type the host from its Devices card."}
        </Text>
      ) : null}
      {phase === "done" && report !== null ? (
        <Text className="text-xs text-foreground-muted" selectable>
          {sweepSummary(report)}
        </Text>
      ) : null}
    </View>
  );
}
