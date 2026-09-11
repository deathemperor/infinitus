import Constants from "expo-constants";
import { useCallback, useEffect, useRef, useState } from "react";
import { ActivityIndicator, Platform, View } from "react-native";

import { AppText as Text } from "../../components/AppText";
import { ErrorBanner } from "../../components/ErrorBanner";
import { randomHex } from "../../lib/uuid";
import { ConnectionSheetButton } from "../connection/ConnectionSheetButton";
import { askForApproval, waitForDecision } from "./pairingApproval";
import { approvalOrigin, deviceLabel, outcomeMessage } from "./pairingApproval.logic";

type Phase =
  | { readonly kind: "idle" }
  | { readonly kind: "asking" }
  | { readonly kind: "waiting"; readonly matchCode: string };

/**
 * "Ask this Mac to approve" on the add-connection form (#710): instead of
 * typing the Devices card's code, the phone files a request with the server at
 * the Host field's address and shows a four-character match code; the Mac's
 * Devices card lists the request beside the same code, and its Approve hands
 * the phone the one-time credential, which `onCredential` pairs with as if it
 * had been typed. The secret the phone made up stays in this component.
 */
export function InfinitusAskToApprove(props: {
  readonly host: string;
  readonly disabled?: boolean;
  readonly onCredential: (credential: string) => void;
}) {
  const { host, onCredential } = props;
  const [phase, setPhase] = useState<Phase>({ kind: "idle" });
  // Remembered with the host it was about: a new host makes the banner stale.
  const [notice, setNotice] = useState<{ host: string; message: string } | null>(null);
  const wait = useRef<AbortController | null>(null);

  useEffect(() => () => wait.current?.abort(), []);

  const ask = useCallback(async () => {
    const origin = approvalOrigin(host);
    if (origin === null) {
      setNotice({ host, message: "Enter the Mac's host first." });
      return;
    }
    wait.current?.abort();
    const controller = new AbortController();
    wait.current = controller;
    setNotice(null);
    setPhase({ kind: "asking" });
    const secret = randomHex(24);
    const asked = await askForApproval({
      origin,
      deviceName: deviceLabel(Constants.deviceName),
      os: Platform.OS,
      secret,
      signal: controller.signal,
    });
    if (controller.signal.aborted) return;
    if (asked.kind !== "asked") {
      const message = outcomeMessage({ kind: asked.kind }, host);
      setNotice(message === null ? null : { host, message });
      setPhase({ kind: "idle" });
      return;
    }
    setPhase({ kind: "waiting", matchCode: asked.matchCode });
    const outcome = await waitForDecision({
      origin,
      id: asked.id,
      secret,
      deadlineMillis: asked.deadlineMillis,
      signal: controller.signal,
    });
    if (controller.signal.aborted) return;
    setPhase({ kind: "idle" });
    const message = outcomeMessage(outcome, host);
    setNotice(message === null ? null : { host, message });
    if (outcome.kind === "approved") onCredential(outcome.credential);
  }, [host, onCredential]);

  const cancel = useCallback(() => {
    wait.current?.abort();
    wait.current = null;
    setPhase({ kind: "idle" });
  }, []);

  if (phase.kind === "waiting") {
    return (
      <View
        collapsable={false}
        className="gap-3 rounded-[14px] border border-input-border bg-input px-4 py-3.5"
      >
        <View className="flex-row items-center gap-2">
          <ActivityIndicator colorClassName="accent-icon" size="small" />
          <Text className="shrink text-sm text-foreground">
            Waiting for the Mac at {host.trim()}. In its Devices card, approve the request showing
            this code:
          </Text>
        </View>
        <Text
          accessibilityLabel={`Match code ${phase.matchCode.split("").join(" ")}`}
          className="text-center text-3xl font-t3-bold tracking-[6px] text-foreground"
        >
          {phase.matchCode}
        </Text>
        <ConnectionSheetButton
          icon="xmark"
          label="Cancel"
          tone="secondary"
          compact
          onPress={cancel}
        />
      </View>
    );
  }

  return (
    <View collapsable={false} className="gap-2">
      <ConnectionSheetButton
        icon="checkmark.shield"
        label={phase.kind === "asking" ? "Asking the Mac…" : "Ask this Mac to approve"}
        disabled={props.disabled === true || phase.kind === "asking" || host.trim() === ""}
        tone="secondary"
        onPress={() => {
          void ask();
        }}
      />
      {notice !== null && notice.host === host ? <ErrorBanner message={notice.message} /> : null}
    </View>
  );
}
