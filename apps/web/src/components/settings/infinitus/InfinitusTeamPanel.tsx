/**
 * Settings › Team (#1313): the team this Mac is in, read over the
 * control socket's `team-status`, with Fetch now / Publish now; for a
 * leader the pending requests' Approve / Decline, Remove / Promote on the
 * roster, the invite code and who
 * may request to join. Every member picks the audience per kind and keeps
 * projects private. With no team the page offers Join — this Mac's roster
 * name as the argument, the team code or invite link on `infinitus.secret` —
 * and Create: team name, your name, an empty private repo's URL, and the
 * remote's write token on the secret channel when it needs one (an ssh remote
 * needs none and goes over `infinitus.command`). Delegated control (spec §8):
 * the grants this Mac gave (add / revoke), the teammates' commands waiting
 * for its tap (Allow / Deny), and on each member what they let you do; the
 * driving itself is `infinitusctl team drive`, not a page. Every secret field is
 * `type="password"`, never remembered, cleared on submit; a minted code is
 * shown once and never logged; the Mac's own error verbatim, the value never
 * in it.
 *
 * @module InfinitusTeamPanel
 */
import * as Redacted from "effect/Redacted";
import { useCallback, useEffect, useState } from "react";

import { infinitusEnvironment } from "~/state/infinitus";
import { useAtomCommand } from "~/state/use-atom-command";

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
import { infinitusCommandFailure, infinitusPanelMessage } from "./panel.logic";
import {
  infinitusSecretFailure,
  parseTeamCode,
  parseTeamStatus,
  relativeUnix,
  TEAM_CAPABILITIES,
  TEAM_KINDS,
  TEAM_SHARE_TARGETS,
  teamCommandInput,
  teamCreateCommandInput,
  teamCreateDraft,
  teamCreateSecretArgs,
  teamCreateSupported,
  teamExclusionSlug,
  teamGrantAudience,
  teamGrantDraft,
  teamGrantSummary,
  teamJoinLink,
  teamJoinSecretArgs,
  teamJoinSupported,
  teamMemberName,
  teamMemberSummary,
  teamPendingSummary,
  teamRoleLabel,
  teamStatusSupported,
  type TeamAction,
  type TeamStatus,
} from "./team.logic";

const UNSUPPORTED = "This Infinitus build has no team commands (needs ≥ 0.5.0-alpha.17).";

export function InfinitusTeamPanel() {
  const { environmentId, capability, snapshot } = useInfinitusEnvironment();
  const runCommand = useAtomCommand(infinitusEnvironment.command, { reportFailure: false });
  const runSecret = useAtomCommand(infinitusEnvironment.secret, { reportFailure: false });
  const nowMs = useRelativeTimeTick(30_000);
  /** `undefined` before the first read; null once the Mac says it is in no team. */
  const [team, setTeam] = useState<TeamStatus | null | undefined>(undefined);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<TeamAction["type"] | "join" | "create" | null>(null);
  const [joinName, setJoinName] = useState("");
  /** The code, a secret: in memory only, cleared on submit, gone with the page. */
  // A join link the desktop received (infinitus://join/…) lands here as the
  // code, once: on mount when the link opened this page, by subscription when
  // it arrived with the page already open. The user still presses Request to join.
  const [joinCode, setJoinCode] = useState(() => usePendingTeamJoinStore.getState().take() ?? "");
  useEffect(
    () =>
      usePendingTeamJoinStore.subscribe((state) => {
        if (state.code === null) return;
        setJoinCode(usePendingTeamJoinStore.getState().take() ?? "");
      }),
    [],
  );
  const [joinError, setJoinError] = useState<string | null>(null);
  const [createName, setCreateName] = useState("");
  const [createLeader, setCreateLeader] = useState("");
  const [createRemote, setCreateRemote] = useState("");
  /** The remote's write token, a secret: in memory only, cleared on submit. */
  const [createToken, setCreateToken] = useState("");
  const [createError, setCreateError] = useState<string | null>(null);
  /** The code minted last, shown once; gone with the page. */
  const [minted, setMinted] = useState<string | null>(null);
  const [copied, setCopied] = useState<"code" | "link" | null>(null);
  const [exclusionDraft, setExclusionDraft] = useState("");
  const [grantAudience, setGrantAudience] = useState("leaders");
  const [grantCapabilities, setGrantCapabilities] = useState<ReadonlyArray<string>>(["view"]);
  const [grantThreads, setGrantThreads] = useState("");
  const [grantPreauthorized, setGrantPreauthorized] = useState<ReadonlyArray<string>>([]);
  const [leaveOpen, setLeaveOpen] = useState(false);

  const supported =
    snapshot !== null && snapshot.available && teamStatusSupported(snapshot.commands);
  const joinSupported = snapshot !== null && teamJoinSupported(snapshot.commands);
  const createSupported = snapshot !== null && teamCreateSupported(snapshot.commands);

  const applyStatus = useCallback((result: unknown) => {
    const parsed = parseTeamStatus(result);
    if (parsed === null) {
      setError("Infinitus answered team-status with a shape this build cannot read.");
      return;
    }
    setError(null);
    setTeam(parsed.team);
  }, []);

  /** One secret-free verb; every one but publish, code and leave answers team-status. */
  const send = useCallback(
    async (action: TeamAction) => {
      if (environmentId === null) return;
      const result = await runCommand({ environmentId, input: teamCommandInput(action) });
      if (result._tag === "Failure") {
        setError(infinitusCommandFailure(result.cause).message);
        return;
      }
      if (action.type === "code") {
        const code = parseTeamCode(result.value.result);
        if (code === null) {
          setError("Infinitus answered team-code with a shape this build cannot read.");
          return;
        }
        setError(null);
        setCopied(null);
        setMinted(code.code);
        return;
      }
      if (
        action.type === "publish" ||
        action.type === "leave" ||
        action.type === "grant" ||
        action.type === "revoke" ||
        action.type === "allow" ||
        action.type === "deny"
      ) {
        // Publish answers what it pushed, leave {left}, grant the grant,
        // revoke {removed}, allow/deny the ack; a read follows so the page
        // shows the state it changed.
        const status = await runCommand({
          environmentId,
          input: teamCommandInput({ type: "status" }),
        });
        if (status._tag === "Failure") {
          setError(infinitusCommandFailure(status.cause).message);
          return;
        }
        applyStatus(status.value.result);
        return;
      }
      applyStatus(result.value.result);
    },
    [applyStatus, environmentId, runCommand],
  );

  /** A write from a control: busy while the Mac answers. */
  const run = async (action: Exclude<TeamAction, { type: "status" }>) => {
    setBusy(action.type);
    await send(action);
    setBusy(null);
  };

  useEffect(() => {
    if (!supported) return;
    void send({ type: "status" });
  }, [send, supported]);

  const join = async () => {
    if (environmentId === null) return;
    const name = teamMemberName(joinName);
    const code = joinCode.trim();
    setJoinCode("");
    if (name === null) {
      setJoinError("Give this Mac a name for the roster.");
      return;
    }
    if (code.length === 0) {
      setJoinError("Paste the team code or invite link.");
      return;
    }
    setBusy("join");
    setJoinError(null);
    const result = await runSecret({
      environmentId,
      input: { ...teamJoinSecretArgs(name), secret: Redacted.make(code) },
    });
    setBusy(null);
    if (result._tag === "Failure") {
      setJoinError(infinitusSecretFailure(result.cause));
      return;
    }
    applyStatus(result.value.result);
  };

  const create = async () => {
    if (environmentId === null) return;
    const draft = teamCreateDraft(createName, createLeader, createRemote);
    const token = createToken.trim();
    setCreateToken("");
    if (draft === null) {
      setCreateError(
        "Fill in the team name, your name and the repo URL (each under 128 characters).",
      );
      return;
    }
    setBusy("create");
    setCreateError(null);
    // A token rides the secret channel; without one the verb needs no stdin
    // and goes over the plain command like every other write.
    const result =
      token.length === 0
        ? await runCommand({ environmentId, input: teamCreateCommandInput(draft) })
        : await runSecret({
            environmentId,
            input: { ...teamCreateSecretArgs(draft), secret: Redacted.make(token) },
          });
    setBusy(null);
    if (result._tag === "Failure") {
      setCreateError(
        token.length === 0
          ? infinitusCommandFailure(result.cause).message
          : infinitusSecretFailure(result.cause),
      );
      return;
    }
    applyStatus(result.value.result);
  };

  const copy = async (what: "code" | "link") => {
    if (minted === null) return;
    try {
      await navigator.clipboard.writeText(what === "code" ? minted : teamJoinLink(minted));
      setCopied(what);
    } catch {
      setError("Copy failed — select the code and copy it by hand.");
    }
  };

  const addGrant = async () => {
    const draft = teamGrantDraft(
      grantAudience,
      grantCapabilities,
      grantThreads,
      grantPreauthorized,
    );
    if (draft === null) {
      setError("Pick who and at least one capability.");
      return;
    }
    setGrantThreads("");
    await run({ type: "grant", draft });
  };

  const toggle = (list: ReadonlyArray<string>, item: string, on: boolean) =>
    on ? (list.includes(item) ? list : [...list, item]) : list.filter((c) => c !== item);

  const addExclusion = async () => {
    const slug = teamExclusionSlug(exclusionDraft);
    if (slug === null) {
      setError("A project is its folder's name, not a path.");
      return;
    }
    setExclusionDraft("");
    await run({ type: "exclude", slug, on: true });
  };

  if (capability !== true || snapshot === null || !snapshot.available || !supported) {
    const state =
      capability !== true
        ? "unsupported"
        : snapshot === null
          ? "loading"
          : !snapshot.available
            ? "unavailable"
            : "empty";
    return (
      <SettingsPageContainer>
        <SettingsSection id="infinitus-team" title="Team">
          <InfinitusPanelNotice
            message={infinitusPanelMessage(state, snapshot?.unavailableReason, UNSUPPORTED)}
          />
        </SettingsSection>
      </SettingsPageContainer>
    );
  }

  const isLeader = team?.role === "leader";
  const inTeam = team !== null && team !== undefined;

  return (
    <SettingsPageContainer>
      <SettingsSection id="infinitus-team" title="Team">
        {team === undefined ? (
          <InfinitusPanelNotice message="Reading the team…" />
        ) : team === null ? (
          <InfinitusPanelNotice message="This Mac is not in a team." />
        ) : (
          <>
            <SettingsRow
              title={team.name}
              description={`${teamRoleLabel(team.role)} · ${team.remote} · fetched ${relativeUnix(team.lastFetch, nowMs)} · published ${relativeUnix(team.lastPublish, nowMs)}`}
              control={
                <>
                  <Button
                    size="sm"
                    variant="outline"
                    disabled={busy !== null}
                    onClick={() => void run({ type: "fetch" })}
                  >
                    {busy === "fetch" ? "Fetching…" : "Fetch now"}
                  </Button>
                  <Button
                    size="sm"
                    variant="outline"
                    disabled={busy !== null || team.role === "pending"}
                    onClick={() => void run({ type: "publish" })}
                  >
                    {busy === "publish" ? "Publishing…" : "Publish now"}
                  </Button>
                </>
              }
            />
            {team.role === "pending" ? (
              <InfinitusPanelNotice message="Waiting for a leader to approve you." />
            ) : null}
            {team.lastError === null || team.lastError === undefined ? null : (
              <p role="alert" className="px-3 py-2 text-[13px] text-destructive sm:px-4">
                {team.lastError}
              </p>
            )}
          </>
        )}
        {error === null ? null : (
          <p role="alert" className="px-3 py-2 text-[13px] text-destructive sm:px-4">
            {error}
          </p>
        )}
      </SettingsSection>
      {!inTeam ? null : (
        <SettingsSection title="Members">
          {team.members.length === 0 ? (
            <InfinitusPanelNotice message="No roster yet." />
          ) : (
            team.members.map((member) => (
              <SettingsRow
                key={member.kid}
                title={member.name}
                description={
                  (member.controls?.length ?? 0) > 0
                    ? `${teamMemberSummary(member, nowMs)} · lets you ${member.controls!.join(", ")}`
                    : teamMemberSummary(member, nowMs)
                }
                control={
                  isLeader && !member.isMe ? (
                    <>
                      {member.role === "leader" ? null : (
                        <Button
                          size="sm"
                          variant="outline"
                          disabled={busy !== null}
                          aria-label={`Promote ${member.name}`}
                          onClick={() => void run({ type: "promote", kid: member.kid })}
                        >
                          Make leader
                        </Button>
                      )}
                      {member.founder === true ? null : (
                        <Button
                          size="sm"
                          variant="outline"
                          disabled={busy !== null}
                          aria-label={`Remove ${member.name}`}
                          onClick={() => void run({ type: "remove", kid: member.kid })}
                        >
                          Remove
                        </Button>
                      )}
                    </>
                  ) : undefined
                }
              />
            ))
          )}
        </SettingsSection>
      )}
      {!inTeam || !isLeader ? null : (
        <SettingsSection title="Requests">
          {(team.requests ?? []).length === 0 ? (
            <InfinitusPanelNotice message="No one is asking to join." />
          ) : (
            (team.requests ?? []).map((request) => (
              <SettingsRow
                key={request.kid}
                title={request.name}
                description={`${request.platform ?? "?"} · ${(request.devices ?? []).join(", ")} · ${relativeUnix(request.at, nowMs)}`}
                control={
                  <>
                    <Button
                      size="sm"
                      variant="outline"
                      disabled={busy !== null}
                      aria-label={`Decline ${request.name}`}
                      onClick={() => void run({ type: "decline", kid: request.kid })}
                    >
                      Decline
                    </Button>
                    <Button
                      size="sm"
                      disabled={busy !== null}
                      aria-label={`Approve ${request.name}`}
                      onClick={() => void run({ type: "approve", kid: request.kid })}
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
      {!inTeam || !isLeader ? null : (
        <SettingsSection id="infinitus-team-invite" title="Invite">
          <SettingsRow
            title="Team code"
            description="A code is good for 7 days; an invite link is a code with a one-time nonce this Mac approves on its own. Both are secrets: shown once, never logged."
            control={
              <>
                <Button
                  size="sm"
                  variant="outline"
                  disabled={busy !== null}
                  onClick={() => void run({ type: "code", days: 7, invite: false })}
                >
                  {busy === "code" ? "Minting…" : "Mint a code"}
                </Button>
                <Button
                  size="sm"
                  disabled={busy !== null}
                  onClick={() => void run({ type: "code", days: 7, invite: true })}
                >
                  Mint an invite link
                </Button>
              </>
            }
          />
          {minted === null ? null : (
            <div className="flex flex-col gap-2 px-3 py-2 sm:px-4">
              {/* The code is a secret: masked, in memory only, gone with the page. */}
              <Input
                type="password"
                size="sm"
                readOnly
                autoComplete="off"
                aria-label="Minted team code"
                value={minted}
              />
              <div className="flex items-center justify-end gap-2">
                <Button size="sm" variant="outline" onClick={() => void copy("code")}>
                  {copied === "code" ? "Copied" : "Copy code"}
                </Button>
                <Button size="sm" variant="outline" onClick={() => void copy("link")}>
                  {copied === "link" ? "Copied" : "Copy link"}
                </Button>
                <Button size="sm" variant="ghost" onClick={() => setMinted(null)}>
                  Done
                </Button>
              </div>
              <p className="text-[13px] text-muted-foreground">
                The link opens the Infinitus app on a phone or this desktop; the code pastes into
                Settings › Team on any Mac.
              </p>
            </div>
          )}
          <SettingsRow
            title="Who may request to join"
            description="With a code, anyone holding one this team minted; off, nobody — invite links still work."
            control={
              <Select
                disabled={busy !== null}
                value={team.policy?.requests ?? "code"}
                onValueChange={(value) => {
                  if (value === "code" || value === "off")
                    void run({ type: "policy", requests: value });
                }}
              >
                <SelectTrigger
                  size="sm"
                  className="w-full sm:w-44"
                  aria-label="Who may request to join"
                >
                  <SelectValue>
                    {team.policy?.requests === "off" ? "Nobody" : "With a code"}
                  </SelectValue>
                </SelectTrigger>
                <SelectPopup align="end" alignItemWithTrigger={false}>
                  <SelectItem hideIndicator value="code">
                    With a code
                  </SelectItem>
                  <SelectItem hideIndicator value="off">
                    Nobody
                  </SelectItem>
                </SelectPopup>
              </Select>
            }
          />
        </SettingsSection>
      )}
      {!inTeam || team.role === "pending" ? null : (
        <SettingsSection id="infinitus-team-sharing" title="Sharing">
          {TEAM_KINDS.map(({ kind, label }) => {
            const current = team.shares?.[kind] ?? "leaders";
            return (
              <SettingsRow
                key={kind}
                title={label}
                control={
                  <Select
                    disabled={busy !== null}
                    value={current}
                    onValueChange={(value) => {
                      const target = TEAM_SHARE_TARGETS.find((choice) => choice.target === value);
                      if (target !== undefined)
                        void run({ type: "share", kind, target: target.target });
                    }}
                  >
                    <SelectTrigger
                      size="sm"
                      className="w-full sm:w-40"
                      aria-label={`Share ${kind} with`}
                    >
                      <SelectValue>
                        {TEAM_SHARE_TARGETS.find((choice) => choice.target === current)?.label ??
                          current}
                      </SelectValue>
                    </SelectTrigger>
                    <SelectPopup align="end" alignItemWithTrigger={false}>
                      {TEAM_SHARE_TARGETS.map((choice) => (
                        <SelectItem hideIndicator key={choice.target} value={choice.target}>
                          {choice.label}
                        </SelectItem>
                      ))}
                    </SelectPopup>
                  </Select>
                }
              />
            );
          })}
          <p className="px-3 pb-2 text-[13px] text-muted-foreground sm:px-4">
            Applies to the next publish; history already shared stays as it was. Everything is
            redacted on the Mac before it is sealed to its audience.
          </p>
        </SettingsSection>
      )}
      {!inTeam || team.role === "pending" ? null : (
        <SettingsSection id="infinitus-team-exclusions" title="Private projects">
          {(team.exclusions ?? []).map((slug) => (
            <SettingsRow
              key={slug}
              title={slug}
              description="Kept off every kind: stats, threads, transcripts."
              control={
                <Button
                  size="sm"
                  variant="outline"
                  disabled={busy !== null}
                  aria-label={`Share ${slug} again`}
                  onClick={() => void run({ type: "exclude", slug, on: false })}
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
              void addExclusion();
            }}
          >
            <Input
              size="sm"
              aria-label="Project folder name"
              placeholder="Project folder name, e.g. secret-repo"
              autoComplete="off"
              spellCheck={false}
              value={exclusionDraft}
              disabled={busy !== null}
              onChange={(event) => setExclusionDraft(event.currentTarget.value)}
            />
            <Button type="submit" size="sm" variant="outline" disabled={busy !== null}>
              Keep private
            </Button>
          </form>
        </SettingsSection>
      )}
      {!inTeam || team.role === "pending" ? null : (
        <SettingsSection id="infinitus-team-grants" title="Delegated control">
          {(team.grants ?? []).map((grant) => (
            <SettingsRow
              key={grant.id}
              title={teamGrantAudience(grant.audience, team.members)}
              description={teamGrantSummary(grant, nowMs)}
              control={
                <Button
                  size="sm"
                  variant="outline"
                  disabled={busy !== null}
                  aria-label={`Revoke grant ${grant.id}`}
                  onClick={() => void run({ type: "revoke", id: grant.id })}
                >
                  Revoke
                </Button>
              }
            />
          ))}
          <form
            className="flex flex-col gap-2 px-3 py-2 sm:px-4"
            onSubmit={(event) => {
              event.preventDefault();
              void addGrant();
            }}
          >
            <div className="flex items-center gap-2">
              <Select
                disabled={busy !== null}
                value={grantAudience}
                onValueChange={(value) => {
                  if (typeof value === "string") setGrantAudience(value);
                }}
              >
                <SelectTrigger size="sm" className="w-full sm:w-48" aria-label="Grant to">
                  <SelectValue>
                    {grantAudience === "leaders"
                      ? "Leaders"
                      : grantAudience === "team"
                        ? "Whole team"
                        : (team.members.find((member) => member.kid === grantAudience)?.name ??
                          grantAudience)}
                  </SelectValue>
                </SelectTrigger>
                <SelectPopup align="start" alignItemWithTrigger={false}>
                  <SelectItem hideIndicator value="leaders">
                    Leaders
                  </SelectItem>
                  <SelectItem hideIndicator value="team">
                    Whole team
                  </SelectItem>
                  {team.members
                    .filter((member) => !member.isMe)
                    .map((member) => (
                      <SelectItem hideIndicator key={member.kid} value={member.kid}>
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
                value={grantThreads}
                disabled={busy !== null}
                onChange={(event) => setGrantThreads(event.currentTarget.value)}
              />
            </div>
            {TEAM_CAPABILITIES.map(({ capability, label, asks }) => (
              <div key={capability} className="flex items-center gap-4 text-[13px]">
                <label className="flex items-center gap-2">
                  <Checkbox
                    aria-label={`Allow ${capability}`}
                    checked={grantCapabilities.includes(capability)}
                    disabled={busy !== null}
                    onCheckedChange={(checked) =>
                      setGrantCapabilities((list) => toggle(list, capability, checked === true))
                    }
                  />
                  {label}
                </label>
                {!asks || !grantCapabilities.includes(capability) ? null : (
                  <label className="flex items-center gap-2 text-muted-foreground">
                    <Checkbox
                      aria-label={`${capability} without asking`}
                      checked={grantPreauthorized.includes(capability)}
                      disabled={busy !== null}
                      onCheckedChange={(checked) =>
                        setGrantPreauthorized((list) => toggle(list, capability, checked === true))
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
          <p className="px-3 pb-2 text-[13px] text-muted-foreground sm:px-4">
            A teammate drives with <code>infinitusctl team drive</code>. Interrupt and new ask you
            first unless ticked; view and send never ask.
          </p>
        </SettingsSection>
      )}
      {!inTeam || (team.pending ?? []).length === 0 ? null : (
        <SettingsSection id="infinitus-team-pending" title="Waiting for you">
          {(team.pending ?? []).map((pending) => (
            <SettingsRow
              key={pending.id}
              title={pending.name}
              description={teamPendingSummary(pending, nowMs)}
              control={
                <>
                  <Button
                    size="sm"
                    variant="outline"
                    disabled={busy !== null}
                    aria-label={`Deny ${pending.id}`}
                    onClick={() => void run({ type: "deny", id: pending.id })}
                  >
                    Deny
                  </Button>
                  <Button
                    size="sm"
                    disabled={busy !== null}
                    aria-label={`Allow ${pending.id}`}
                    onClick={() => void run({ type: "allow", id: pending.id })}
                  >
                    Allow
                  </Button>
                </>
              }
            />
          ))}
        </SettingsSection>
      )}
      {!inTeam ? null : (
        <SettingsSection id="infinitus-team-leave" title="Leave">
          <SettingsRow
            title="Leave this team"
            description="Deletes this Mac's files on the store, tells the leaders and forgets the team here. Your identity stays."
            control={
              <Button
                size="sm"
                variant="destructive"
                disabled={busy !== null}
                onClick={() => setLeaveOpen(true)}
              >
                Leave…
              </Button>
            }
          />
          <AlertDialog
            open={leaveOpen}
            onOpenChange={(open) => {
              if (busy === "leave") return;
              setLeaveOpen(open);
            }}
          >
            <AlertDialogPopup>
              <AlertDialogHeader>
                <AlertDialogTitle>Leave {team.name}?</AlertDialogTitle>
                <AlertDialogDescription>
                  What this Mac published is deleted from the store and the team forgotten here.
                  Joining again takes a new code.
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
                    void run({ type: "leave" }).then(() => setLeaveOpen(false));
                  }}
                >
                  {busy === "leave" ? "Leaving…" : "Leave"}
                </Button>
              </AlertDialogFooter>
            </AlertDialogPopup>
          </AlertDialog>
        </SettingsSection>
      )}
      {team !== null ? null : (
        <SettingsSection id="infinitus-team-join" title="Join a team">
          {joinSupported ? (
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
                value={joinName}
                disabled={busy !== null}
                onChange={(event) => setJoinName(event.currentTarget.value)}
              />
              {/* The code is a secret: masked, never remembered, cleared on submit. */}
              <Input
                type="password"
                size="sm"
                autoComplete="off"
                spellCheck={false}
                aria-label="Team code or invite link"
                placeholder="Team code or invite link"
                value={joinCode}
                disabled={busy !== null}
                onChange={(event) => setJoinCode(event.currentTarget.value)}
              />
              <div className="flex items-center justify-end gap-2">
                <Button type="submit" size="sm" disabled={busy !== null}>
                  {busy === "join" ? "Requesting…" : "Request to join"}
                </Button>
              </div>
              {joinError === null ? null : (
                <p role="alert" className="text-[13px] text-destructive">
                  {joinError}
                </p>
              )}
            </form>
          ) : (
            <InfinitusPanelNotice message="This Infinitus build does not take a team code from here." />
          )}
        </SettingsSection>
      )}
      {team !== null ? null : (
        <SettingsSection id="infinitus-team-create" title="Create a team">
          {createSupported ? (
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
                value={createName}
                disabled={busy !== null}
                onChange={(event) => setCreateName(event.currentTarget.value)}
              />
              <Input
                size="sm"
                aria-label="Your name as leader"
                placeholder="Your name in the roster"
                autoComplete="off"
                value={createLeader}
                disabled={busy !== null}
                onChange={(event) => setCreateLeader(event.currentTarget.value)}
              />
              <Input
                size="sm"
                aria-label="Empty private repo URL"
                placeholder="Empty private repo URL"
                autoComplete="off"
                spellCheck={false}
                value={createRemote}
                disabled={busy !== null}
                onChange={(event) => setCreateRemote(event.currentTarget.value)}
              />
              {/* The token is a secret: masked, never remembered, cleared on submit. */}
              <Input
                type="password"
                size="sm"
                autoComplete="off"
                spellCheck={false}
                aria-label="Write token (optional)"
                placeholder="Write token (optional; stays in the Mac's keychain)"
                value={createToken}
                disabled={busy !== null}
                onChange={(event) => setCreateToken(event.currentTarget.value)}
              />
              <p className="text-[13px] text-muted-foreground">
                Paste the URL of an empty private repo and a token that can push to it, or an ssh
                URL your Mac can already use. The only out-of-app step.
              </p>
              <div className="flex items-center justify-end gap-2">
                <Button type="submit" size="sm" disabled={busy !== null}>
                  {busy === "create" ? "Creating…" : "Create team"}
                </Button>
              </div>
              {createError === null ? null : (
                <p role="alert" className="text-[13px] text-destructive">
                  {createError}
                </p>
              )}
            </form>
          ) : (
            <InfinitusPanelNotice message="This Infinitus build does not create a team from here." />
          )}
        </SettingsSection>
      )}
    </SettingsPageContainer>
  );
}
