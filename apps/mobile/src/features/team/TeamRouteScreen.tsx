import { useAuth } from "@clerk/expo";
import type { InfinitusTeamClient } from "@infinitus/client-runtime/relay/infinitusTeam";
import {
  machineIsOnline,
  machineNow,
  memberSummary,
  parseJoinInput,
  pendingSummary,
  relativeTime,
} from "@infinitus/client-runtime/relay/infinitusTeamLogic";
import type { TeamListRow, TeamSnapshot } from "@infinitus/contracts/relayInfinitusTeam";
import { CONNECT_NAME } from "@infinitus/shared/productName";
import { type StaticScreenProps, useNavigation } from "@react-navigation/native";
import { useCallback, useEffect, useRef, useState } from "react";
import { Platform, Pressable, ScrollView, View } from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";

import { AndroidScreenHeader } from "../../components/AndroidScreenHeader";
import { AppText as Text, AppTextInput as TextInput } from "../../components/AppText";
import { EmptyState } from "../../components/EmptyState";
import { ErrorBanner } from "../../components/ErrorBanner";
import { NativeStackScreenOptions } from "../../native/StackHeader";
import { useNowMinute } from "../accounts/useNowMinute";
import { hasCloudPublicConfig } from "../cloud/publicConfig";
import { ConnectionSheetButton } from "../connection/ConnectionSheetButton";
import { SettingsSection } from "../settings/components/SettingsSection";
import { teamErrorMessage, teamMemberName, teamRoleLabel } from "./team.logic";
import { useInfinitusTeamClient } from "./useInfinitusTeamClient";

export type TeamRouteParams = {
  /** The token an invite link (`https://infinitus.run/join#<token>`) carried; prefills Join. */
  readonly code?: string;
};

const INPUT =
  "rounded-[14px] border border-input-border bg-input px-4 py-3.5 text-base text-foreground";

/** Settings › Team on Infinitus Connect (#1592): the teams the signed-in
    user is in, read and changed on the relay as that user, no Mac in the
    loop. Members with their machines and live threads, the leader's
    requests, what is waiting for the user's Allow, and Join. Creating,
    sharing, grants, transcripts and leaving are the desktop's. */
export function TeamRouteScreen({ route }: StaticScreenProps<TeamRouteParams | undefined>) {
  const navigation = useNavigation();
  const insets = useSafeAreaInsets();
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
        {hasCloudPublicConfig() ? (
          <ConnectedTeam code={code} />
        ) : (
          <EmptyState
            title={`${CONNECT_NAME} is not configured`}
            detail="Team needs it: a team lives on your account, not on a Mac."
          />
        )}
      </ScrollView>
    </View>
  );
}

function ConnectedTeam(props: { readonly code: string }) {
  const navigation = useNavigation();
  const { isLoaded, isSignedIn } = useAuth({ treatPendingAsSignedOut: false });
  if (!isLoaded) {
    return <Text className="px-2 text-sm text-foreground-muted">Checking your sign-in…</Text>;
  }
  if (!isSignedIn) {
    return (
      <EmptyState
        title={`Sign in to ${CONNECT_NAME}`}
        detail="Teams live on your account: join from here, and every machine you sign in on shares with them."
        actionLabel="Sign in"
        onAction={() => navigation.navigate("SettingsSheet", { screen: "SettingsAuth" })}
      />
    );
  }
  return <TeamPane code={props.code} />;
}

function TeamPane(props: { readonly code: string }) {
  const client = useInfinitusTeamClient();
  const nowMs = useNowMinute();
  /** `undefined` before the first read. */
  const [teams, setTeams] = useState<ReadonlyArray<TeamListRow> | undefined>(undefined);
  const [teamId, setTeamId] = useState<string | null>(null);
  const [team, setTeam] = useState<TeamSnapshot | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const fail = useCallback((cause: unknown) => setError(teamErrorMessage(cause)), []);

  const loadTeam = useCallback(
    async (id: string) => {
      try {
        setTeam(await client.getTeam(id));
        setError(null);
      } catch (cause) {
        fail(cause);
      }
    },
    [client, fail],
  );

  // The picked team survives a reload without being an effect dependency,
  // so the first read runs once per client.
  const pickedRef = useRef<string | null>(null);
  const loadTeams = useCallback(
    async (prefer?: string) => {
      try {
        const list = await client.listTeams();
        setTeams(list);
        setError(null);
        const wanted = prefer ?? pickedRef.current;
        const next = list.find((row) => row.teamId === wanted)?.teamId ?? list[0]?.teamId ?? null;
        pickedRef.current = next;
        setTeamId(next);
        if (next === null) setTeam(null);
        else await loadTeam(next);
      } catch (cause) {
        setTeams([]);
        fail(cause);
      }
    },
    [client, fail, loadTeam],
  );

  useEffect(() => {
    void loadTeams();
  }, [loadTeams]);

  /** One relay write that answers the snapshot. */
  const apply = async (label: string, run: () => Promise<TeamSnapshot>) => {
    setBusy(label);
    try {
      setTeam(await run());
      setError(null);
    } catch (cause) {
      fail(cause);
    } finally {
      setBusy(null);
    }
  };

  /** One relay write that answers nothing; the snapshot is read again. */
  const applyThenReload = async (label: string, run: () => Promise<unknown>) => {
    setBusy(label);
    try {
      await run();
      setError(null);
      if (teamId !== null) await loadTeam(teamId);
    } catch (cause) {
      fail(cause);
    } finally {
      setBusy(null);
    }
  };

  const id = team?.teamId ?? null;
  const isLeader = team?.role === "leader";

  return (
    <View className="gap-5">
      {teams === undefined ? (
        <Text className="px-2 text-sm text-foreground-muted">Reading your teams…</Text>
      ) : null}
      {teams !== undefined && teams.length === 0 ? (
        <Text className="px-2 text-sm text-foreground-muted">
          You are in no team yet. Join one below, or create one on the desktop.
        </Text>
      ) : null}
      {teams !== undefined && teams.length > 1 ? (
        <SettingsSection title="Teams">
          {teams.map((row, index) => (
            <Pressable
              key={row.teamId}
              accessibilityRole="button"
              accessibilityState={{ selected: row.teamId === teamId }}
              className={
                index === teams.length - 1
                  ? "flex-row items-center justify-between px-4 py-3"
                  : "flex-row items-center justify-between border-b border-border px-4 py-3"
              }
              onPress={() => {
                pickedRef.current = row.teamId;
                setTeamId(row.teamId);
                void loadTeam(row.teamId);
              }}
            >
              <Text className="text-base text-foreground">{row.name}</Text>
              <Text className="text-xs text-foreground-muted">
                {row.teamId === teamId ? "shown" : teamRoleLabel(row.role)}
              </Text>
            </Pressable>
          ))}
        </SettingsSection>
      ) : null}
      {notice ? <Text className="px-2 text-sm text-foreground-muted">{notice}</Text> : null}
      {error ? <ErrorBanner message={error} /> : null}

      {team !== null && id !== null ? (
        <>
          <SettingsSection title={team.name}>
            <Text className="px-4 pt-3 text-xs text-foreground-muted">
              {`${teamRoleLabel(team.role)} · you are ${team.me.name}`}
            </Text>
            {team.members.map((member, index) => {
              const machines = member.machines.map((machine) => {
                const now = machineNow(machine);
                const live = now.live.map((row) => row.title).join(", ");
                return [
                  machine.label,
                  machineIsOnline(machine, nowMs) ? "online" : "offline",
                  `published ${relativeTime(machine.lastPublished, nowMs)}`,
                  live.length === 0 ? null : `live: ${live}`,
                  now.blockers.length === 0 ? null : `blocked: ${now.blockers.join(", ")}`,
                ]
                  .filter((part) => part !== null)
                  .join(" · ");
              });
              return (
                <View
                  key={member.userId}
                  className={
                    index === team.members.length - 1
                      ? "gap-0.5 px-4 py-3"
                      : "gap-0.5 border-b border-border px-4 py-3"
                  }
                >
                  <Text className="text-base text-foreground">
                    {member.userId === team.me.userId ? `${member.name} (you)` : member.name}
                  </Text>
                  <Text className="text-xs text-foreground-muted">
                    {memberSummary(member, nowMs)}
                  </Text>
                  {machines.map((line, machineIndex) => (
                    <Text
                      key={member.machines[machineIndex]!.environmentId}
                      className="text-xs text-foreground-tertiary"
                    >
                      {line}
                    </Text>
                  ))}
                </View>
              );
            })}
          </SettingsSection>

          {isLeader ? (
            <SettingsSection title="Requests">
              {team.requests.length === 0 ? (
                <Text className="px-4 py-3 text-sm text-foreground-muted">
                  Nobody is waiting to join.
                </Text>
              ) : (
                team.requests.map((request, index) => (
                  <View
                    key={request.userId}
                    className={
                      index === team.requests.length - 1
                        ? "gap-2 px-4 py-3"
                        : "gap-2 border-b border-border px-4 py-3"
                    }
                  >
                    <Text className="text-base text-foreground">{request.name}</Text>
                    <Text className="text-xs text-foreground-muted">
                      {`asked ${relativeTime(request.at, nowMs)}`}
                    </Text>
                    <View className="flex-row gap-2">
                      <ConnectionSheetButton
                        icon="checkmark"
                        label="Approve"
                        tone="primary"
                        compact
                        disabled={busy !== null}
                        onPress={() =>
                          void apply("approve", () => client.approveRequest(id, request.userId))
                        }
                      />
                      <ConnectionSheetButton
                        icon="xmark"
                        label="Decline"
                        tone="danger"
                        compact
                        disabled={busy !== null}
                        onPress={() =>
                          void apply("decline", () => client.declineRequest(id, request.userId))
                        }
                      />
                    </View>
                  </View>
                ))
              )}
            </SettingsSection>
          ) : null}

          {team.pending.length > 0 ? (
            <SettingsSection title="Waiting for you">
              {team.pending.map((pending, index) => (
                <View
                  key={pending.commandId}
                  className={
                    index === team.pending.length - 1
                      ? "gap-2 px-4 py-3"
                      : "gap-2 border-b border-border px-4 py-3"
                  }
                >
                  <Text className="text-base text-foreground">{pending.fromName}</Text>
                  <Text className="text-xs text-foreground-muted">
                    {pendingSummary(pending, nowMs)}
                  </Text>
                  <View className="flex-row gap-2">
                    <ConnectionSheetButton
                      icon="checkmark"
                      label="Allow"
                      tone="primary"
                      compact
                      disabled={busy !== null}
                      onPress={() =>
                        void applyThenReload("allow", () =>
                          client.allowCommand(id, pending.commandId),
                        )
                      }
                    />
                    <ConnectionSheetButton
                      icon="xmark"
                      label="Deny"
                      tone="danger"
                      compact
                      disabled={busy !== null}
                      onPress={() =>
                        void applyThenReload("deny", () =>
                          client.denyCommand(id, pending.commandId),
                        )
                      }
                    />
                  </View>
                </View>
              ))}
            </SettingsSection>
          ) : null}

          <ConnectionSheetButton
            icon="arrow.clockwise"
            label={busy === "refresh" ? "Refreshing…" : "Refresh"}
            disabled={busy !== null}
            onPress={() => void applyThenReload("refresh", () => Promise.resolve())}
          />
        </>
      ) : null}

      <JoinSection
        client={client}
        code={props.code}
        busy={busy}
        setBusy={setBusy}
        onJoined={async (joined) => {
          setNotice(
            joined.status === "pending"
              ? "Your request is in; a leader approves it."
              : "You are in.",
          );
          await loadTeams(joined.teamId);
        }}
      />
      <Text className="px-2 text-xs text-foreground-tertiary">
        Creating a team, choosing what each machine shares, delegated control and leaving are on the
        desktop.
      </Text>
    </View>
  );
}

function JoinSection(props: {
  readonly client: InfinitusTeamClient;
  readonly code: string;
  readonly busy: string | null;
  readonly setBusy: (busy: string | null) => void;
  readonly onJoined: (joined: { teamId: string; status: "member" | "pending" }) => Promise<void>;
}) {
  const [name, setName] = useState("");
  /** The token, a secret: in memory only, cleared on submit, gone with the screen. */
  const [token, setToken] = useState(props.code);
  const [error, setError] = useState<string | null>(null);

  const join = async () => {
    const memberName = teamMemberName(name);
    const parsed = parseJoinInput(token);
    if (memberName === null) {
      setError("Give yourself a name for the roster.");
      return;
    }
    if (parsed === null) {
      setError("Paste the invite token or link.");
      return;
    }
    props.setBusy("join");
    setError(null);
    try {
      const joined = await props.client.joinTeam({ token: parsed, memberName });
      setToken("");
      await props.onJoined(joined);
    } catch (cause) {
      setError(teamErrorMessage(cause));
    } finally {
      props.setBusy(null);
    }
  };

  return (
    <SettingsSection title="Join a team">
      <View className="gap-3 p-4">
        <Text className="text-sm text-foreground-muted">
          Ask a leader for an invite. A one-use invite joins you at once; a reusable one asks, and a
          leader approves.
        </Text>
        <TextInput
          autoCapitalize="words"
          autoCorrect={false}
          placeholder="Your name on the roster"
          value={name}
          onChangeText={setName}
          className={INPUT}
        />
        <TextInput
          autoCapitalize="none"
          autoCorrect={false}
          secureTextEntry
          placeholder="Invite token or link"
          value={token}
          onChangeText={setToken}
          className={INPUT}
        />
        {error ? <ErrorBanner message={error} /> : null}
        <ConnectionSheetButton
          icon="link"
          label={props.busy === "join" ? "Joining…" : "Join"}
          tone="primary"
          disabled={props.busy !== null}
          onPress={() => void join()}
        />
      </View>
    </SettingsSection>
  );
}
