/**
 * Settings › Team on Infinitus Connect (#1592): the teams the signed-in
 * user is in, read and changed on the relay with the user's Clerk token.
 * Signed out, one card offers the sign-in the sidebar offers. Signed in:
 * a team picker when in several; Members (a leader's Promote / Demote /
 * Remove; a row expands to the member's threads index, a thread to its
 * transcript rows), Requests, Invites (minted once, shown once, with Copy
 * and Copy link), Sharing, Policy, Grants and Waiting for you, Leave; then
 * Join (the bare token or either link shape) and Create. Private projects
 * stay the Mac's, over its `team-exclusions` / `team-exclude` verbs. Every
 * relay error is its reason verbatim.
 *
 * @module InfinitusTeamPanel
 */
import { useAuth } from "@clerk/react";
import type { InfinitusTeamClient } from "@infinitus/client-runtime/relay/infinitusTeam";
import {
  audienceLabel,
  buildJoinLink,
  grantSummary,
  machineIsOnline,
  machineNow,
  memberSummary,
  parseJoinInput,
  pendingSummary,
  relativeTime,
  threadsIndex,
  transcriptRows,
  untilTime,
  type TeamThreadRow,
  type TeamTranscriptRow,
} from "@infinitus/client-runtime/relay/infinitusTeamLogic";
import type {
  TeamListRow,
  TeamMemberRow,
  TeamShares,
  TeamSnapshot,
} from "@infinitus/contracts/relayInfinitusTeam";
import { CONNECT_NAME } from "@infinitus/shared/productName";
import { useCallback, useEffect, useRef, useState } from "react";

import { infinitusEnvironment } from "~/state/infinitus";
import { useAtomCommand } from "~/state/use-atom-command";

import { hasCloudPublicConfig } from "../../../cloud/publicConfig";
import { useInfinitusConnectAuthPrompt } from "../../clerk/useInfinitusConnectAuthPrompt";
import { usePendingTeamJoinStore } from "../../deepLinks/pendingTeamJoin";
import {
  AlertDialog,
  AlertDialogClose,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogPopup,
  AlertDialogTitle,
} from "../../ui/alert-dialog";
import { Button } from "../../ui/button";
import { Checkbox } from "../../ui/checkbox";
import { Input } from "../../ui/input";
import { Select, SelectItem, SelectPopup, SelectTrigger, SelectValue } from "../../ui/select";
import {
  SettingsPageContainer,
  SettingsRow,
  SettingsSection,
  useRelativeTimeTick,
} from "../settingsLayout";
import { InfinitusPanelNotice, useInfinitusEnvironment } from "./InfinitusPrefsPanel";
import { infinitusCommandFailure } from "./panel.logic";
import {
  parseTeamExclusions,
  TEAM_CAPABILITIES,
  TEAM_EXCLUSIONS_INPUT,
  TEAM_KINDS,
  TEAM_SHARE_TARGETS,
  teamErrorMessage,
  teamExcludeInput,
  teamExclusionSlug,
  teamExclusionsSupported,
  teamGrantDraft,
  teamMemberName,
  teamRoleLabel,
} from "./team.logic";
import { useInfinitusTeamClient } from "./useInfinitusTeamClient";

export function InfinitusTeamPanel() {
  if (!hasCloudPublicConfig()) {
    return (
      <SettingsPageContainer>
        <SettingsSection id="infinitus-team" title="Team">
          <InfinitusPanelNotice
            message={`${CONNECT_NAME} is not configured on this build; Team needs it.`}
          />
        </SettingsSection>
        <PrivateProjectsSection />
      </SettingsPageContainer>
    );
  }
  return <ConnectedTeamPanel />;
}

function ConnectedTeamPanel() {
  const { isLoaded, isSignedIn } = useAuth();
  const { openAuthPrompt } = useInfinitusConnectAuthPrompt();
  const client = useInfinitusTeamClient();
  if (!isLoaded) {
    return (
      <SettingsPageContainer>
        <SettingsSection id="infinitus-team" title="Team">
          <InfinitusPanelNotice message="Loading…" />
        </SettingsSection>
      </SettingsPageContainer>
    );
  }
  if (!isSignedIn) {
    return (
      <SettingsPageContainer>
        <SettingsSection id="infinitus-team" title="Team">
          <SettingsRow
            title={`Sign in to ${CONNECT_NAME} to use Team`}
            description="Teams live on your account: join from any of your machines, and what each one shares reaches your teammates through the relay."
            control={
              <Button size="sm" onClick={openAuthPrompt}>
                Sign in
              </Button>
            }
          />
        </SettingsSection>
        <PrivateProjectsSection />
      </SettingsPageContainer>
    );
  }
  return <TeamPane client={client} />;
}

type Busy = string | null;

function TeamPane({ client }: { readonly client: InfinitusTeamClient }) {
  const { environmentId } = useInfinitusEnvironment();
  const nowMs = useRelativeTimeTick(30_000);
  /** `undefined` before the first read. */
  const [teams, setTeams] = useState<ReadonlyArray<TeamListRow> | undefined>(undefined);
  const [teamId, setTeamId] = useState<string | null>(null);
  const [team, setTeam] = useState<TeamSnapshot | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<Busy>(null);
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

  const isLeader = team?.role === "leader";
  const id = team?.teamId ?? null;

  return (
    <SettingsPageContainer>
      <SettingsSection id="infinitus-team" title="Team">
        {teams === undefined ? (
          <InfinitusPanelNotice message="Reading your teams…" />
        ) : teams.length === 0 ? (
          <InfinitusPanelNotice message="You are in no team yet. Join one below, or create one." />
        ) : teams.length === 1 && team !== null ? (
          <SettingsRow
            title={team.name}
            description={`${teamRoleLabel(team.role)} · you are ${team.me.name}`}
          />
        ) : (
          <SettingsRow
            title="Team"
            description={
              team === null ? "Reading…" : `${teamRoleLabel(team.role)} · you are ${team.me.name}`
            }
            control={
              <Select
                value={teamId ?? ""}
                onValueChange={(value) => {
                  if (typeof value === "string" && value.length > 0) {
                    pickedRef.current = value;
                    setTeamId(value);
                    void loadTeam(value);
                  }
                }}
              >
                <SelectTrigger size="sm" className="w-full sm:w-56" aria-label="Team">
                  <SelectValue>
                    {teams.find((row) => row.teamId === teamId)?.name ?? "Pick a team"}
                  </SelectValue>
                </SelectTrigger>
                <SelectPopup align="end" alignItemWithTrigger={false}>
                  {teams.map((row) => (
                    <SelectItem hideIndicator key={row.teamId} value={row.teamId}>
                      {row.name}
                    </SelectItem>
                  ))}
                </SelectPopup>
              </Select>
            }
          />
        )}
        {notice === null ? null : <InfinitusPanelNotice message={notice} />}
        {error === null ? null : (
          <p role="alert" className="px-3 py-2 text-sm text-destructive sm:px-4">
            {error}
          </p>
        )}
      </SettingsSection>
      {team === null || id === null ? null : (
        <>
          <MembersSection
            client={client}
            team={team}
            nowMs={nowMs}
            busy={busy}
            onPromote={(userId) => apply("promote", () => client.promoteMember(id, userId))}
            onDemote={(userId) => apply("demote", () => client.demoteMember(id, userId))}
            onRemove={(userId) => apply("remove", () => client.removeMember(id, userId))}
            onError={fail}
          />
          {!isLeader ? null : (
            <SettingsSection title="Requests">
              {team.requests.length === 0 ? (
                <InfinitusPanelNotice message="No one is asking to join." />
              ) : (
                team.requests.map((request) => (
                  <SettingsRow
                    key={request.userId}
                    title={request.name}
                    description={`asked ${relativeTime(request.at, nowMs)}`}
                    control={
                      <>
                        <Button
                          size="sm"
                          variant="outline"
                          disabled={busy !== null}
                          aria-label={`Decline ${request.name}`}
                          onClick={() =>
                            void apply("decline", () => client.declineRequest(id, request.userId))
                          }
                        >
                          Decline
                        </Button>
                        <Button
                          size="sm"
                          disabled={busy !== null}
                          aria-label={`Approve ${request.name}`}
                          onClick={() =>
                            void apply("approve", () => client.approveRequest(id, request.userId))
                          }
                        >
                          Approve
                        </Button>
                      </>
                    }
                  />
                ))
              )}
            </SettingsSection>
          )}
          {!isLeader ? null : (
            <InvitesSection
              client={client}
              team={team}
              nowMs={nowMs}
              busy={busy}
              setBusy={setBusy}
              onError={fail}
              onRevoke={(inviteId) =>
                applyThenReload("revoke-invite", () => client.revokeInvite(id, inviteId))
              }
              onPolicy={(requests) => apply("policy", () => client.updatePolicy(id, requests))}
            />
          )}
          <SettingsSection id="infinitus-team-sharing" title="Sharing">
            {TEAM_KINDS.map(({ kind, label }) => (
              <SettingsRow
                key={kind}
                title={label}
                control={
                  <Select
                    disabled={busy !== null}
                    value={team.me.shares[kind]}
                    onValueChange={(value) => {
                      if (value === "off" || value === "leaders" || value === "team") {
                        const shares: TeamShares = { ...team.me.shares, [kind]: value };
                        void apply(`share-${kind}`, () => client.updateMe(id, { shares }));
                      }
                    }}
                  >
                    <SelectTrigger
                      size="sm"
                      className="w-full sm:w-40"
                      aria-label={`Share ${kind} with`}
                    >
                      <SelectValue>
                        {TEAM_SHARE_TARGETS.find((entry) => entry.target === team.me.shares[kind])
                          ?.label ?? "Nobody"}
                      </SelectValue>
                    </SelectTrigger>
                    <SelectPopup align="end" alignItemWithTrigger={false}>
                      {TEAM_SHARE_TARGETS.map(({ target, label: targetLabel }) => (
                        <SelectItem hideIndicator key={target} value={target}>
                          {targetLabel}
                        </SelectItem>
                      ))}
                    </SelectPopup>
                  </Select>
                }
              />
            ))}
            <p className="px-3 pb-2 text-sm text-muted-foreground sm:px-4">
              What every machine of yours publishes to this team, once a minute for Now and every
              five for the rest. Transcripts are redacted before they leave, and kept 90 days.
            </p>
          </SettingsSection>
          <GrantsSection
            team={team}
            nowMs={nowMs}
            busy={busy}
            environmentId={environmentId}
            onGrant={(draft) => applyThenReload("grant", () => client.createGrant(id, draft))}
            onRevoke={(grantId) =>
              applyThenReload("revoke-grant", () => client.revokeGrant(id, grantId))
            }
            onAllow={(commandId) =>
              applyThenReload("allow", () => client.allowCommand(id, commandId))
            }
            onDeny={(commandId) => applyThenReload("deny", () => client.denyCommand(id, commandId))}
            onError={setError}
          />
          <LeaveSection
            team={team}
            busy={busy}
            onLeave={async () => {
              setBusy("leave");
              try {
                await client.leaveTeam(id);
                setError(null);
                setTeam(null);
                await loadTeams("");
              } catch (cause) {
                fail(cause);
              } finally {
                setBusy(null);
              }
            }}
          />
        </>
      )}
      <JoinSection
        client={client}
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
      <CreateSection
        client={client}
        busy={busy}
        setBusy={setBusy}
        onCreated={async (created) => {
          setNotice(null);
          await loadTeams(created.teamId);
        }}
      />
      <PrivateProjectsSection />
    </SettingsPageContainer>
  );
}

function MembersSection({
  client,
  team,
  nowMs,
  busy,
  onPromote,
  onDemote,
  onRemove,
  onError,
}: {
  readonly client: InfinitusTeamClient;
  readonly team: TeamSnapshot;
  readonly nowMs: number;
  readonly busy: Busy;
  readonly onPromote: (userId: string) => Promise<void>;
  readonly onDemote: (userId: string) => Promise<void>;
  readonly onRemove: (userId: string) => Promise<void>;
  readonly onError: (cause: unknown) => void;
}) {
  const isLeader = team.role === "leader";
  const [expanded, setExpanded] = useState<string | null>(null);
  /** userId → environmentId → the member's threads index. */
  const [indexes, setIndexes] = useState<
    Record<string, ReadonlyArray<{ environmentId: string; threads: ReadonlyArray<TeamThreadRow> }>>
  >({});
  const [transcript, setTranscript] = useState<{
    readonly key: string;
    readonly rows: ReadonlyArray<TeamTranscriptRow>;
  } | null>(null);
  const [reading, setReading] = useState<string | null>(null);

  const expand = async (member: TeamMemberRow) => {
    if (expanded === member.userId) {
      setExpanded(null);
      return;
    }
    setExpanded(member.userId);
    if (indexes[member.userId] !== undefined) return;
    try {
      const documents = await client.listDocuments(team.teamId, {
        userId: member.userId,
        kind: "threads",
      });
      setIndexes((current) => ({
        ...current,
        [member.userId]: documents.map((document) => ({
          environmentId: document.environmentId,
          threads: threadsIndex(document.body),
        })),
      }));
    } catch (cause) {
      onError(cause);
    }
  };

  const open = async (member: TeamMemberRow, environmentId: string, threadId: string) => {
    const key = `${member.userId}/${environmentId}/${threadId}`;
    if (transcript?.key === key) {
      setTranscript(null);
      return;
    }
    setReading(key);
    try {
      const input = { teamId: team.teamId, userId: member.userId, environmentId, threadId };
      const chunks = await client.listTranscriptChunks(input);
      const rows: Array<TeamTranscriptRow> = [];
      for (const chunk of chunks) {
        rows.push(
          ...transcriptRows(await client.readTranscriptChunk({ ...input, seq: chunk.seq })),
        );
      }
      setTranscript({ key, rows });
    } catch (cause) {
      onError(cause);
    } finally {
      setReading(null);
    }
  };

  return (
    <SettingsSection title="Members">
      {team.members.map((member) => {
        const isMe = member.userId === team.me.userId;
        const machineLabel = (environmentId: string) =>
          member.machines.find((machine) => machine.environmentId === environmentId)?.label ??
          environmentId;
        return (
          <div key={member.userId}>
            <SettingsRow
              title={member.name}
              description={memberSummary(member, nowMs)}
              control={
                <>
                  <Button
                    size="sm"
                    variant="ghost"
                    aria-label={`${expanded === member.userId ? "Collapse" : "Expand"} ${member.name}`}
                    onClick={() => void expand(member)}
                  >
                    {expanded === member.userId ? "Less" : "Threads"}
                  </Button>
                  {isLeader && !isMe ? (
                    <>
                      <Button
                        size="sm"
                        variant="outline"
                        disabled={busy !== null}
                        aria-label={`${member.role === "leader" ? "Demote" : "Promote"} ${member.name}`}
                        onClick={() =>
                          void (member.role === "leader"
                            ? onDemote(member.userId)
                            : onPromote(member.userId))
                        }
                      >
                        {member.role === "leader" ? "Make member" : "Make leader"}
                      </Button>
                      {member.founder ? null : (
                        <Button
                          size="sm"
                          variant="outline"
                          disabled={busy !== null}
                          aria-label={`Remove ${member.name}`}
                          onClick={() => void onRemove(member.userId)}
                        >
                          Remove
                        </Button>
                      )}
                    </>
                  ) : null}
                </>
              }
            />
            {expanded !== member.userId ? null : (
              <div className="flex flex-col gap-2 px-3 pb-3 text-sm sm:px-4">
                {member.machines.map((machine) => {
                  const now = machineNow(machine);
                  return (
                    <p key={machine.environmentId} className="text-muted-foreground">
                      {machine.label} · {machineIsOnline(machine, nowMs) ? "online" : "offline"} ·
                      published {relativeTime(machine.lastPublished, nowMs)}
                      {now.live.length === 0
                        ? ""
                        : ` · live: ${now.live.map((row) => row.title).join(", ")}`}
                      {now.blockers.length === 0 ? "" : ` · blocked: ${now.blockers.join(", ")}`}
                    </p>
                  );
                })}
                {indexes[member.userId] === undefined ? (
                  <p className="text-muted-foreground">Reading their threads…</p>
                ) : indexes[member.userId]!.every((entry) => entry.threads.length === 0) ? (
                  <p className="text-muted-foreground">No threads shared with you.</p>
                ) : (
                  indexes[member.userId]!.map((entry) => (
                    <ul key={entry.environmentId} className="flex flex-col gap-1">
                      {entry.threads.map((thread) => {
                        const key = `${member.userId}/${entry.environmentId}/${thread.id}`;
                        return (
                          <li key={thread.id} className="flex flex-col gap-1">
                            <button
                              type="button"
                              className="text-left hover:underline"
                              disabled={reading !== null}
                              onClick={() => void open(member, entry.environmentId, thread.id)}
                            >
                              {thread.title}{" "}
                              <span className="text-muted-foreground">
                                · {thread.project} · {thread.status} ·{" "}
                                {machineLabel(entry.environmentId)}
                              </span>
                            </button>
                            {transcript?.key !== key ? null : transcript.rows.length === 0 ? (
                              <p className="text-muted-foreground">
                                No transcript shared with you.
                              </p>
                            ) : (
                              <ol className="flex max-h-96 flex-col gap-1 overflow-auto rounded border border-border p-2">
                                {transcript.rows.map((row, index) => (
                                  // A row's position is stable: the transcript is read whole.
                                  // oxlint-disable-next-line react/no-array-index-key
                                  <li key={index} className="whitespace-pre-wrap break-words">
                                    <span className="text-muted-foreground">{row.role}: </span>
                                    {row.text}
                                  </li>
                                ))}
                              </ol>
                            )}
                          </li>
                        );
                      })}
                    </ul>
                  ))
                )}
              </div>
            )}
          </div>
        );
      })}
    </SettingsSection>
  );
}

function InvitesSection({
  client,
  team,
  nowMs,
  busy,
  setBusy,
  onError,
  onRevoke,
  onPolicy,
}: {
  readonly client: InfinitusTeamClient;
  readonly team: TeamSnapshot;
  readonly nowMs: number;
  readonly busy: Busy;
  readonly setBusy: (busy: Busy) => void;
  readonly onError: (cause: unknown) => void;
  readonly onRevoke: (inviteId: string) => Promise<void>;
  readonly onPolicy: (requests: "code" | "off") => Promise<void>;
}) {
  const [days, setDays] = useState("7");
  const [oneUse, setOneUse] = useState(true);
  /** The token minted last, shown once; gone with the page. */
  const [minted, setMinted] = useState<string | null>(null);
  const [copied, setCopied] = useState<"token" | "link" | null>(null);
  const [copyError, setCopyError] = useState<string | null>(null);

  const mint = async () => {
    const n = Math.min(Math.max(Number.parseInt(days, 10) || 7, 1), 3650);
    setBusy("invite");
    try {
      const created = await client.createInvite(team.teamId, { days: n, oneUse });
      setMinted(created.token);
      setCopied(null);
      setCopyError(null);
    } catch (cause) {
      onError(cause);
    } finally {
      setBusy(null);
    }
  };

  const copy = async (what: "token" | "link") => {
    if (minted === null) return;
    try {
      await navigator.clipboard.writeText(what === "token" ? minted : buildJoinLink(minted));
      setCopied(what);
    } catch {
      setCopyError("Copy failed — select the token and copy it by hand.");
    }
  };

  return (
    <SettingsSection id="infinitus-team-invite" title="Invites">
      <SettingsRow
        title="Mint an invite"
        description="A one-use invite joins whoever opens it at once; a reusable one asks, and a leader approves. Both are secrets: shown once, never logged."
        control={
          <>
            <Input
              size="sm"
              type="number"
              min={1}
              max={3650}
              aria-label="Days the invite is good for"
              className="w-20"
              value={days}
              disabled={busy !== null}
              onChange={(event) => setDays(event.currentTarget.value)}
            />
            <label className="flex items-center gap-2 text-sm">
              <Checkbox
                aria-label="One use"
                checked={oneUse}
                disabled={busy !== null}
                onCheckedChange={(checked) => setOneUse(checked === true)}
              />
              one use
            </label>
            <Button size="sm" disabled={busy !== null} onClick={() => void mint()}>
              {busy === "invite" ? "Minting…" : "Mint"}
            </Button>
          </>
        }
      />
      {minted === null ? null : (
        <div className="flex flex-col gap-2 px-3 py-2 sm:px-4">
          {/* The token is a secret: masked, in memory only, gone with the page. */}
          <Input
            type="password"
            size="sm"
            readOnly
            autoComplete="off"
            aria-label="Minted invite token"
            value={minted}
          />
          <div className="flex items-center justify-end gap-2">
            <Button size="sm" variant="outline" onClick={() => void copy("token")}>
              {copied === "token" ? "Copied" : "Copy token"}
            </Button>
            <Button size="sm" variant="outline" onClick={() => void copy("link")}>
              {copied === "link" ? "Copied" : "Copy link"}
            </Button>
            <Button size="sm" variant="ghost" onClick={() => setMinted(null)}>
              Done
            </Button>
          </div>
          {copyError === null ? null : (
            <p role="alert" className="text-sm text-destructive">
              {copyError}
            </p>
          )}
          <p className="text-sm text-muted-foreground">
            The link opens Infinitus on a phone or a desktop; the token pastes into Settings › Team
            anywhere.
          </p>
        </div>
      )}
      {team.invites.map((invite) => (
        <SettingsRow
          key={invite.inviteId}
          title={invite.oneUse ? "One-use invite" : "Reusable invite"}
          description={
            invite.usedBy !== null ? "used" : `expires ${untilTime(invite.expiresAt, nowMs)}`
          }
          control={
            <Button
              size="sm"
              variant="outline"
              disabled={busy !== null || invite.usedBy !== null}
              aria-label={`Revoke invite ${invite.inviteId}`}
              onClick={() => void onRevoke(invite.inviteId)}
            >
              Revoke
            </Button>
          }
        />
      ))}
      <SettingsRow
        title="Who may request to join"
        description="With a reusable invite, anyone holding one; off, nobody — one-use invites still join."
        control={
          <Select
            disabled={busy !== null}
            value={team.policy.requests}
            onValueChange={(value) => {
              if (value === "code" || value === "off") void onPolicy(value);
            }}
          >
            <SelectTrigger
              size="sm"
              className="w-full sm:w-44"
              aria-label="Who may request to join"
            >
              <SelectValue>
                {team.policy.requests === "off" ? "Nobody" : "With an invite"}
              </SelectValue>
            </SelectTrigger>
            <SelectPopup align="end" alignItemWithTrigger={false}>
              <SelectItem hideIndicator value="code">
                With an invite
              </SelectItem>
              <SelectItem hideIndicator value="off">
                Nobody
              </SelectItem>
            </SelectPopup>
          </Select>
        }
      />
    </SettingsSection>
  );
}

function GrantsSection({
  team,
  nowMs,
  busy,
  environmentId,
  onGrant,
  onRevoke,
  onAllow,
  onDeny,
  onError,
}: {
  readonly team: TeamSnapshot;
  readonly nowMs: number;
  readonly busy: Busy;
  readonly environmentId: ReturnType<typeof useInfinitusEnvironment>["environmentId"];
  readonly onGrant: (draft: NonNullable<ReturnType<typeof teamGrantDraft>>) => Promise<void>;
  readonly onRevoke: (grantId: string) => Promise<void>;
  readonly onAllow: (commandId: string) => Promise<void>;
  readonly onDeny: (commandId: string) => Promise<void>;
  readonly onError: (message: string) => void;
}) {
  const [audience, setAudience] = useState("leaders");
  const [capabilities, setCapabilities] = useState<ReadonlyArray<string>>(["view"]);
  const [threads, setThreads] = useState("");
  const [preauthorized, setPreauthorized] = useState<ReadonlyArray<string>>([]);
  const toggle = (list: ReadonlyArray<string>, item: string, on: boolean) =>
    on ? (list.includes(item) ? list : [...list, item]) : list.filter((c) => c !== item);
  const others = team.members.filter((member) => member.userId !== team.me.userId);

  return (
    <>
      <SettingsSection id="infinitus-team-grants" title="Delegated control">
        {team.grants.map((grant) => (
          <SettingsRow
            key={grant.grantId}
            title={audienceLabel(grant.audience, team.members)}
            description={grantSummary(grant, nowMs)}
            control={
              <Button
                size="sm"
                variant="outline"
                disabled={busy !== null}
                aria-label={`Revoke grant ${grant.grantId}`}
                onClick={() => void onRevoke(grant.grantId)}
              >
                Revoke
              </Button>
            }
          />
        ))}
        {environmentId === null ? (
          <InfinitusPanelNotice message="Grants name this desktop's environment; connect it first." />
        ) : (
          <form
            className="flex flex-col gap-2 px-3 py-2 sm:px-4"
            onSubmit={(event) => {
              event.preventDefault();
              const draft = teamGrantDraft({
                environmentId,
                audience,
                capabilities,
                threads,
                preauthorized,
              });
              if (draft === null) {
                onError("Pick who and at least one capability.");
                return;
              }
              setThreads("");
              void onGrant(draft);
            }}
          >
            <div className="flex items-center gap-2">
              <Select
                disabled={busy !== null}
                value={audience}
                onValueChange={(value) => {
                  if (typeof value === "string") setAudience(value);
                }}
              >
                <SelectTrigger size="sm" className="w-full sm:w-48" aria-label="Grant to">
                  <SelectValue>
                    {audience === "leaders"
                      ? "Leaders"
                      : audience === "team"
                        ? "Whole team"
                        : (others.find((member) => member.userId === audience)?.name ?? audience)}
                  </SelectValue>
                </SelectTrigger>
                <SelectPopup align="start" alignItemWithTrigger={false}>
                  <SelectItem hideIndicator value="leaders">
                    Leaders
                  </SelectItem>
                  <SelectItem hideIndicator value="team">
                    Whole team
                  </SelectItem>
                  {others.map((member) => (
                    <SelectItem hideIndicator key={member.userId} value={member.userId}>
                      {member.name}
                    </SelectItem>
                  ))}
                </SelectPopup>
              </Select>
              <Input
                size="sm"
                aria-label="Thread ids"
                placeholder="Thread ids, comma-separated; blank = all"
                autoComplete="off"
                spellCheck={false}
                value={threads}
                disabled={busy !== null}
                onChange={(event) => setThreads(event.currentTarget.value)}
              />
            </div>
            {TEAM_CAPABILITIES.map(({ capability, label, asks }) => (
              <div key={capability} className="flex items-center gap-4 text-sm">
                <label className="flex items-center gap-2">
                  <Checkbox
                    aria-label={`Allow ${capability}`}
                    checked={capabilities.includes(capability)}
                    disabled={busy !== null}
                    onCheckedChange={(checked) =>
                      setCapabilities((list) => toggle(list, capability, checked === true))
                    }
                  />
                  {label}
                </label>
                {!asks || !capabilities.includes(capability) ? null : (
                  <label className="flex items-center gap-2 text-muted-foreground">
                    <Checkbox
                      aria-label={`${capability} without asking`}
                      checked={preauthorized.includes(capability)}
                      disabled={busy !== null}
                      onCheckedChange={(checked) =>
                        setPreauthorized((list) => toggle(list, capability, checked === true))
                      }
                    />
                    without asking
                  </label>
                )}
              </div>
            ))}
            <div>
              <Button type="submit" size="sm" variant="outline" disabled={busy !== null}>
                {busy === "grant" ? "Granting…" : "Grant"}
              </Button>
            </div>
          </form>
        )}
        <p className="px-3 pb-2 text-sm text-muted-foreground sm:px-4">
          Interrupt and new ask you first unless ticked; view and send never ask. The desktop runs
          what it is asked within fifteen seconds.
        </p>
      </SettingsSection>
      {team.pending.length === 0 ? null : (
        <SettingsSection id="infinitus-team-pending" title="Waiting for you">
          {team.pending.map((pending) => (
            <SettingsRow
              key={pending.commandId}
              title={pending.fromName}
              description={pendingSummary(pending, nowMs)}
              control={
                <>
                  <Button
                    size="sm"
                    variant="outline"
                    disabled={busy !== null}
                    aria-label={`Deny ${pending.commandId}`}
                    onClick={() => void onDeny(pending.commandId)}
                  >
                    Deny
                  </Button>
                  <Button
                    size="sm"
                    disabled={busy !== null}
                    aria-label={`Allow ${pending.commandId}`}
                    onClick={() => void onAllow(pending.commandId)}
                  >
                    Allow
                  </Button>
                </>
              }
            />
          ))}
        </SettingsSection>
      )}
    </>
  );
}

function LeaveSection({
  team,
  busy,
  onLeave,
}: {
  readonly team: TeamSnapshot;
  readonly busy: Busy;
  readonly onLeave: () => Promise<void>;
}) {
  const [open, setOpen] = useState(false);
  return (
    <SettingsSection id="infinitus-team-leave" title="Leave">
      <SettingsRow
        title="Leave this team"
        description="What your machines published to it, transcripts included, is deleted. Joining again takes a new invite."
        control={
          <Button
            size="sm"
            variant="destructive"
            disabled={busy !== null}
            onClick={() => setOpen(true)}
          >
            Leave…
          </Button>
        }
      />
      <AlertDialog
        open={open}
        onOpenChange={(next) => {
          if (busy === "leave") return;
          setOpen(next);
        }}
      >
        <AlertDialogPopup>
          <AlertDialogHeader>
            <AlertDialogTitle>Leave {team.name}?</AlertDialogTitle>
            <AlertDialogDescription>
              Everything your machines published is deleted from the relay. A last leader promotes
              someone first.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogClose disabled={busy === "leave"} render={<Button variant="outline" />}>
              Cancel
            </AlertDialogClose>
            <Button
              variant="destructive"
              disabled={busy === "leave"}
              onClick={() => {
                void onLeave().then(() => setOpen(false));
              }}
            >
              {busy === "leave" ? "Leaving…" : "Leave"}
            </Button>
          </AlertDialogFooter>
        </AlertDialogPopup>
      </AlertDialog>
    </SettingsSection>
  );
}

function JoinSection({
  client,
  busy,
  setBusy,
  onJoined,
}: {
  readonly client: InfinitusTeamClient;
  readonly busy: Busy;
  readonly setBusy: (busy: Busy) => void;
  readonly onJoined: (joined: { teamId: string; status: "member" | "pending" }) => Promise<void>;
}) {
  const [name, setName] = useState("");
  // A join link the desktop received (infinitus://join/…) lands here once:
  // on mount when the link opened this page, by subscription when it arrived
  // with the page open. The user still presses Join.
  const [token, setToken] = useState(() => usePendingTeamJoinStore.getState().take() ?? "");
  useEffect(
    () =>
      usePendingTeamJoinStore.subscribe((state) => {
        if (state.code === null) return;
        setToken(usePendingTeamJoinStore.getState().take() ?? "");
      }),
    [],
  );
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
    setBusy("join");
    setError(null);
    try {
      const joined = await client.joinTeam({ token: parsed, memberName });
      setToken("");
      await onJoined(joined);
    } catch (cause) {
      setError(teamErrorMessage(cause));
    } finally {
      setBusy(null);
    }
  };

  return (
    <SettingsSection id="infinitus-team-join" title="Join a team">
      <form
        className="flex flex-col gap-2 px-3 py-2 sm:px-4"
        onSubmit={(event) => {
          event.preventDefault();
          void join();
        }}
      >
        <Input
          size="sm"
          aria-label="Your name"
          placeholder="Your name in the roster"
          autoComplete="off"
          value={name}
          disabled={busy !== null}
          onChange={(event) => setName(event.currentTarget.value)}
        />
        {/* The token is a secret: masked, never remembered, cleared on join. */}
        <Input
          type="password"
          size="sm"
          autoComplete="off"
          spellCheck={false}
          aria-label="Invite token or link"
          placeholder="Invite token or link"
          value={token}
          disabled={busy !== null}
          onChange={(event) => setToken(event.currentTarget.value)}
        />
        <div className="flex items-center justify-end gap-2">
          <Button type="submit" size="sm" disabled={busy !== null}>
            {busy === "join" ? "Joining…" : "Join"}
          </Button>
        </div>
        {error === null ? null : (
          <p role="alert" className="text-sm text-destructive">
            {error}
          </p>
        )}
      </form>
    </SettingsSection>
  );
}

function CreateSection({
  client,
  busy,
  setBusy,
  onCreated,
}: {
  readonly client: InfinitusTeamClient;
  readonly busy: Busy;
  readonly setBusy: (busy: Busy) => void;
  readonly onCreated: (created: TeamSnapshot) => Promise<void>;
}) {
  const [name, setName] = useState("");
  const [memberName, setMemberName] = useState("");
  const [error, setError] = useState<string | null>(null);

  const create = async () => {
    const teamName = teamMemberName(name);
    const mine = teamMemberName(memberName);
    if (teamName === null || mine === null) {
      setError("Fill in the team's name and yours (each under 64 characters).");
      return;
    }
    setBusy("create");
    setError(null);
    try {
      const created = await client.createTeam({ name: teamName, memberName: mine });
      setName("");
      await onCreated(created);
    } catch (cause) {
      setError(teamErrorMessage(cause));
    } finally {
      setBusy(null);
    }
  };

  return (
    <SettingsSection id="infinitus-team-create" title="Create a team">
      <form
        className="flex flex-col gap-2 px-3 py-2 sm:px-4"
        onSubmit={(event) => {
          event.preventDefault();
          void create();
        }}
      >
        <Input
          size="sm"
          aria-label="Team name"
          placeholder="Team name"
          autoComplete="off"
          value={name}
          disabled={busy !== null}
          onChange={(event) => setName(event.currentTarget.value)}
        />
        <Input
          size="sm"
          aria-label="Your name as leader"
          placeholder="Your name in the roster"
          autoComplete="off"
          value={memberName}
          disabled={busy !== null}
          onChange={(event) => setMemberName(event.currentTarget.value)}
        />
        <p className="text-sm text-muted-foreground">
          You become its founding leader. Nothing to host: the team lives on {CONNECT_NAME}.
        </p>
        <div className="flex items-center justify-end gap-2">
          <Button type="submit" size="sm" disabled={busy !== null}>
            {busy === "create" ? "Creating…" : "Create team"}
          </Button>
        </div>
        {error === null ? null : (
          <p role="alert" className="text-sm text-destructive">
            {error}
          </p>
        )}
      </form>
    </SettingsSection>
  );
}

/** The Mac's private projects: read over `team-exclusions`, changed over
    `team-exclude`; local to the Mac, never sent anywhere. */
function PrivateProjectsSection() {
  const { environmentId, snapshot } = useInfinitusEnvironment();
  const runCommand = useAtomCommand(infinitusEnvironment.command, { reportFailure: false });
  const supported =
    snapshot !== null && snapshot.available && teamExclusionsSupported(snapshot.commands);
  const [projects, setProjects] = useState<ReadonlyArray<string> | null>(null);
  const [draft, setDraft] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const read = useCallback(async () => {
    if (environmentId === null) return;
    const result = await runCommand({ environmentId, input: TEAM_EXCLUSIONS_INPUT });
    if (result._tag === "Failure") {
      setError(infinitusCommandFailure(result.cause).message);
      return;
    }
    const parsed = parseTeamExclusions(result.value.result);
    if (parsed === null) {
      setError("Infinitus answered team-exclusions with a shape this build cannot read.");
      return;
    }
    setError(null);
    setProjects(parsed);
  }, [environmentId, runCommand]);

  useEffect(() => {
    if (supported) void read();
  }, [read, supported]);

  const write = async (slug: string, on: boolean) => {
    if (environmentId === null) return;
    setBusy(true);
    const result = await runCommand({ environmentId, input: teamExcludeInput(slug, on) });
    if (result._tag === "Failure") setError(infinitusCommandFailure(result.cause).message);
    else await read();
    setBusy(false);
  };

  if (!supported) return null;
  return (
    <SettingsSection id="infinitus-team-private" title="Private projects">
      {(projects ?? []).map((project) => (
        <SettingsRow
          key={project}
          title={project.slice(project.lastIndexOf("/") + 1) || project}
          description={project}
          control={
            <Button
              size="sm"
              variant="outline"
              disabled={busy}
              aria-label={`Share ${project} again`}
              onClick={() => void write(project, false)}
            >
              Share again
            </Button>
          }
        />
      ))}
      <form
        className="flex items-center gap-2 px-3 py-2 sm:px-4"
        onSubmit={(event) => {
          event.preventDefault();
          const slug = teamExclusionSlug(draft);
          if (slug === null) {
            setError("A project is its folder's name or path, without spaces.");
            return;
          }
          setDraft("");
          void write(slug, true);
        }}
      >
        <Input
          size="sm"
          aria-label="Project to keep private"
          placeholder="Project folder or path to keep private"
          autoComplete="off"
          spellCheck={false}
          value={draft}
          disabled={busy}
          onChange={(event) => setDraft(event.currentTarget.value)}
        />
        <Button type="submit" size="sm" variant="outline" disabled={busy}>
          Keep private
        </Button>
      </form>
      <p className="px-3 pb-2 text-sm text-muted-foreground sm:px-4">
        Nothing from a private project leaves this Mac: no thread, no transcript, no stats. Local to
        the Mac, never sent.
      </p>
      {error === null ? null : (
        <p role="alert" className="px-3 py-2 text-sm text-destructive sm:px-4">
          {error}
        </p>
      )}
    </SettingsSection>
  );
}
