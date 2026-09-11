import * as Network from "expo-network";
import { useCallback, useEffect, useRef, useState } from "react";
import { ActivityIndicator, Pressable, View } from "react-native";

import { AppText as Text } from "../../components/AppText";
import { ConnectionSheetButton } from "../connection/ConnectionSheetButton";
import { discoverNearbyServers } from "./lanDiscovery";
import { type NearbyServer } from "./lanDiscovery.logic";

type Phase = "idle" | "scanning" | "done";

/**
 * "Find Macs on this network" on the add-connection form (#651): sweeps the
 * phone's Wi‑Fi for desktop servers and fills the Host field with a tap. The
 * one-time code from the Mac's Devices card is still typed by hand.
 */
export function InfinitusNearbyServers(props: { readonly onPick: (host: string) => void }) {
  const [phase, setPhase] = useState<Phase>("idle");
  const [found, setFound] = useState<ReadonlyArray<NearbyServer>>([]);
  const [notice, setNotice] = useState<string | null>(null);
  const scan = useRef<AbortController | null>(null);

  useEffect(() => () => scan.current?.abort(), []);

  const start = useCallback(async () => {
    scan.current?.abort();
    const controller = new AbortController();
    scan.current = controller;
    setPhase("scanning");
    setFound([]);
    setNotice(null);
    let ownIp: string | null = null;
    try {
      ownIp = await Network.getIpAddressAsync();
    } catch {
      ownIp = null;
    }
    if (ownIp === null || ownIp === "0.0.0.0") {
      setNotice("Join the Mac's Wi‑Fi first.");
      setPhase("done");
      return;
    }
    await discoverNearbyServers({
      ownIp,
      signal: controller.signal,
      onFound: (server) =>
        setFound((current) =>
          current.some((item) => item.host === server.host) ? current : [...current, server],
        ),
    });
    if (!controller.signal.aborted) setPhase("done");
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
          key={server.host}
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
    </View>
  );
}
