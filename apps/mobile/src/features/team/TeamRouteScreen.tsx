import { useAtomValue } from "@effect/atom-react";
import { type StaticScreenProps, useNavigation } from "@react-navigation/native";
import * as Redacted from "effect/Redacted";
import { useCallback, useEffect, useMemo, useState } from "react";
import { Platform, ScrollView, View } from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";

import { AndroidScreenHeader } from "../../components/AndroidScreenHeader";
import { AppText as Text, AppTextInput as TextInput } from "../../components/AppText";
import { EmptyState } from "../../components/EmptyState";
import { ErrorBanner } from "../../components/ErrorBanner";
import { NativeStackScreenOptions } from "../../native/StackHeader";
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
import { useNowMinute } from "../accounts/useNowMinute";
import { ConnectionSheetButton } from "../connection/ConnectionSheetButton";
import { SettingsSection } from "../settings/components/SettingsSection";
import {
  parseTeamStatus,
  relativeUnix,
  secretFailureMessage,
  type TeamAction,
  teamCommandInput,
  teamJoinCode,
  teamJoinSecretArgs,
  teamJoinSupported,
  teamLeads,
  teamMemberName,
  teamMemberSummary,
  teamStatusSupported,
  type TeamStatus,
} from "./team.logic";

export type TeamRouteParams = {
  /** The code an invite link (`https://infinitus.run/join#<code>`) carried; prefills Join. */
  readonly code?: string;
};

const UNSUPPORTED = "This Infinitus build has no team commands (needs ≥ 0.5.0-alpha.17).";
const INPUT =
  "rounded-[14px] border border-input-border bg-input px-4 py-3.5 text-base text-foreground";

/** Settings › Team (#1313): each paired Mac's team, read and driven through
    the T3 server's adapter. Members, the leader's requests, join from a code
    or invite link. Creating, sharing and leaving stay on the Mac (spec §6.3). */
export function TeamRouteScreen({ route }: StaticScreenProps<TeamRouteParams | undefined>) {
  const navigation = useNavigation();
  const insets = useSafeAreaInsets();
  const configs = useAtomValue(environmentServerConfigsAtom);
  const presentations = useAtomValue(environmentPresentations.presentationsAtom);
  const macs = useMemo(() => infinitusMacs(configs, presentations), [configs, presentations]);
  const code = route.params?.code ?? "";

  return (
    <View collapsable={false} className="flex-1 bg-sheet">
      {Platform.OS === "android" ? (
        <>
          <NativeStackScreenOptions options={{ headerShown: false }} />
          <AndroidScreenHeader title="Team" onBack={() => navigation.goBack()} />
        </>
      ) : null}
      <ScrollView
        contentInsetAdjustmentBehavior="automatic"
        contentContainerClassName="gap-5 p-5"
        contentContainerStyle={{ paddingBottom: insets.bottom + 24 }}
        keyboardShouldPersistTaps="handled"
      >
        {macs.length === 0 ? (
          <EmptyState
            title="No Infinitus Mac"
            detail="A team appears here once a paired Mac runs Infinitus. Plain servers have nothing to show."
          />
        ) : (
          macs.map((mac) => (
            <MacTeam key={mac.environmentId} mac={mac} titled={macs.length > 1} code={code} />
          ))
        )}
        {macs.length > 0 ? (
          <Text className="px-2 text-xs text-foreground-tertiary">
            Teams are created, shared and left in Infinitus on the Mac.
          </Text>
        ) : null}
      </ScrollView>
    </View>
  );
}

function MacTeam(props: {
  readonly mac: InfinitusMac;
  readonly titled: boolean;
  readonly code: string;
}) {
  const { mac } = props;
  const view = useEnvironmentQuery(
    infinitusEnvironment.snapshot({ environmentId: mac.environmentId, input: {} }),
  );
  const runCommand = useAtomCommand(infinitusEnvironment.command, { reportFailure: false });
  const runSecret = useAtomCommand(infinitusEnvironment.secret, { reportFailure: false });
  const nowMs = useNowMinute();
  /** `undefined` before the first read; null once the Mac says it is in no team. */
  const [team, setTeam] = useState<TeamStatus | null | undefined>(undefined);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [joinName, setJoinName] = useState("");
  /** The code, a secret: in memory only, cleared on submit, gone with the screen. */
  const [joinCode, setJoinCode] = useState(props.code);
  const [joinError, setJoinError] = useState<string | null>(null);

  const snapshot = view.data;
  const supported =
    snapshot !== null && snapshot.available && teamStatusSupported(snapshot.commands);
  const joinSupported = snapshot !== null && teamJoinSupported(snapshot.commands);

  const applyStatus = useCallback((result: unknown) => {
    const parsed = parseTeamStatus(result);
    if (parsed === null) {
      setError("Infinitus answered team-status with a shape this build cannot read.");
      return;
    }
    setError(null);
    setTeam(parsed.team);
  }, []);

  /** One secret-free verb; every one answers team-status. */
  const send = useCallback(
    async (action: TeamAction) => {
      const result = await runCommand({
        environmentId: mac.environmentId,
        input: teamCommandInput(action),
      });
      if (result._tag === "Failure") {
        setError(commandFailureMessage(result.cause));
        return;
      }
      applyStatus(result.value.result);
    },
    [applyStatus, mac.environmentId, runCommand],
  );

  const run = async (action: Exclude<TeamAction, { type: "status" }>, key: string) => {
    setBusy(key);
    await send(action);
    setBusy(null);
  };

  useEffect(() => {
    if (!supported) return;
    void send({ type: "status" });
  }, [send, supported]);

  const join = async () => {
    const name = teamMemberName(joinName);
    const code = teamJoinCode(joinCode);
    if (name === null) {
      setJoinError("Give this Mac a name for the roster.");
      return;
    }
    if (code.length === 0) {
      setJoinError("Paste the team code or invite link.");
      return;
    }
    setJoinCode("");
    setBusy("join");
    setJoinError(null);
    const result = await runSecret({
      environmentId: mac.environmentId,
      input: { ...teamJoinSecretArgs(name), secret: Redacted.make(code) },
    });
    setBusy(null);
    if (result._tag === "Failure") {
      setJoinError(secretFailureMessage(result.cause));
      return;
    }
    applyStatus(result.value.result);
  };

  return (
    <View className="gap-3">
      {props.titled ? (
        <Text className="px-2 text-sm font-infinitus-medium text-foreground-muted">
          {mac.connected ? mac.label : `${mac.label} · disconnected`}
        </Text>
      ) : null}
      {view.error ? <ErrorBanner message={view.error} /> : null}
      {snapshot === null && view.error === null ? (
        <Text className="px-2 text-sm text-foreground-muted">Reading Infinitus…</Text>
      ) : null}
      {snapshot !== null && !snapshot.available ? (
        <EmptyState
          title="Infinitus is not answering"
          detail={snapshot.unavailableReason ?? "The app is not running on this Mac."}
          actionLabel="Retry"
          onAction={view.refresh}
        />
      ) : null}
      {snapshot !== null && snapshot.available && !supported ? (
        <Text className="px-2 text-sm text-foreground-muted">{UNSUPPORTED}</Text>
      ) : null}
      {supported && error ? <ErrorBanner message={error} /> : null}
      {supported && team === undefined && error === null ? (
        <Text className="px-2 text-sm text-foreground-muted">Reading the team…</Text>
      ) : null}

      {supported && team ? (
        <>
          <SettingsSection title={team.name}>
            {team.members.map((member, index) => (
              <View
                key={member.kid}
                className={
                  index === team.members.length - 1
                    ? "gap-0.5 px-4 py-3"
                    : "gap-0.5 border-b border-border px-4 py-3"
                }
              >
                <Text className="text-base text-foreground">{member.name}</Text>
                <Text className="text-xs text-foreground-muted">
                  {teamMemberSummary(member, nowMs)}
                </Text>
              </View>
            ))}
          </SettingsSection>

          {teamLeads(team) ? (
            <SettingsSection title="Requests">
              {(team.requests?.length ?? 0) === 0 ? (
                <Text className="px-4 py-3 text-sm text-foreground-muted">
                  Nobody is waiting to join.
                </Text>
              ) : (
                team.requests!.map((request, index) => (
                  <View
                    key={request.kid}
                    className={
                      index === team.requests!.length - 1
                        ? "gap-2 px-4 py-3"
                        : "gap-2 border-b border-border px-4 py-3"
                    }
                  >
                    <Text className="text-base text-foreground">{request.name}</Text>
                    <Text className="text-xs text-foreground-muted">
                      {[request.platform, `asked ${relativeUnix(request.at, nowMs)}`]
                        .filter((part) => part !== undefined)
                        .join(" · ")}
                    </Text>
                    <View className="flex-row gap-2">
                      <ConnectionSheetButton
                        icon="checkmark"
                        label="Approve"
                        tone="primary"
                        compact
                        disabled={busy !== null}
                        onPress={() =>
                          void run({ type: "approve", kid: request.kid }, `approve:${request.kid}`)
                        }
                      />
                      <ConnectionSheetButton
                        icon="xmark"
                        label="Deny"
                        tone="danger"
                        compact
                        disabled={busy !== null}
                        onPress={() =>
                          void run({ type: "decline", kid: request.kid }, `decline:${request.kid}`)
                        }
                      />
                    </View>
                  </View>
                ))
              )}
            </SettingsSection>
          ) : null}

          <View className="gap-1.5">
            <ConnectionSheetButton
              icon="arrow.clockwise"
              label={busy === "fetch" ? "Fetching…" : "Fetch now"}
              disabled={busy !== null}
              onPress={() => void run({ type: "fetch" }, "fetch")}
            />
            <Text className="px-2 text-xs text-foreground-tertiary">
              {`Last fetch ${relativeUnix(team.lastFetch, nowMs)} · last publish ${relativeUnix(team.lastPublish, nowMs)}`}
              {team.lastError ? ` · ${team.lastError}` : ""}
            </Text>
          </View>
        </>
      ) : null}

      {supported && team === null ? (
        <SettingsSection title="Join a team">
          <View className="gap-3 p-4">
            {joinSupported ? (
              <>
                <Text className="text-sm text-foreground-muted">
                  This Mac is in no team. Ask a leader for a code or an invite link; a leader
                  approves the request on their Mac.
                </Text>
                <TextInput
                  autoCapitalize="words"
                  autoCorrect={false}
                  placeholder="Your name on the roster"
                  value={joinName}
                  onChangeText={setJoinName}
                  className={INPUT}
                />
                <TextInput
                  autoCapitalize="none"
                  autoCorrect={false}
                  secureTextEntry
                  placeholder="Team code or invite link"
                  value={joinCode}
                  onChangeText={setJoinCode}
                  className={INPUT}
                />
                {joinError ? <ErrorBanner message={joinError} /> : null}
                <ConnectionSheetButton
                  icon="link"
                  label={busy === "join" ? "Requesting…" : "Request to join"}
                  tone="primary"
                  disabled={busy !== null}
                  onPress={() => void join()}
                />
              </>
            ) : (
              <Text className="text-sm text-foreground-muted">
                This Mac is in no team, and this Infinitus build cannot take a code from the phone.
                Join from the Mac.
              </Text>
            )}
          </View>
        </SettingsSection>
      ) : null}
    </View>
  );
}
