/**
 * Settings › Infinitus › Team (#747): the team this Mac is in, read over the
 * control socket's `team-status`, with Fetch now / Publish now and, for a
 * leader, the pending requests' Approve / Decline. With no team the page
 * offers Join — this Mac's roster name as the argument, the team code or
 * invite link on `infinitus.secret` — and Create: team name, your name, an
 * empty private repo's URL, and the remote's write token on the secret
 * channel when it needs one (an ssh remote needs none and goes over
 * `infinitus.command`). A leader also gets Hostnames: the Cloudflare zone
 * and label member hostnames are minted under, with the API token on the
 * secret channel, and Forget token (`--clear`, plain). Every secret field is
 * `type="password"`, never remembered, cleared on submit; the Mac's own error
 * verbatim, the value never in it.
 *
 * @module InfinitusTeamPanel
 */
import * as Redacted from "effect/Redacted";
import { useCallback, useEffect, useState } from "react";

import { infinitusEnvironment } from "~/state/infinitus";
import { useAtomCommand } from "~/state/use-atom-command";

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
import { usePendingTeamJoinStore } from "../../deepLinks/pendingTeamJoin";
import { InfinitusPanelNotice, useInfinitusEnvironment } from "./InfinitusPrefsPanel";
import { infinitusCommandFailure, infinitusPanelMessage } from "./panel.logic";
import {
  infinitusSecretFailure,
  NEVER_PREAUTHORIZED,
  parseTeamGrant,
  parseTeamGrants,
  parseTeamStatus,
  relativeUnix,
  teamCommandInput,
  teamCreateCommandInput,
  teamCreateDraft,
  teamCreateSecretArgs,
  teamCreateSupported,
  TEAM_GRANT_EXPIRY_CHOICES,
  teamGrantAudienceLabel,
  teamGrantCapabilitiesLabel,
  teamGrantCommandInput,
  teamGrantDraftProblem,
  teamGrantExpiryLabel,
  teamGrantsCommandInput,
  teamGrantSessionsLabel,
  teamGrantsSupported,
  TEAM_GRANT_MEANINGS,
  TEAM_GRANT_TIERS,
  parseTeamHostnameReply,
  teamHostnameClearInput,
  teamHostnameDraft,
  teamHostnameSecretArgs,
  teamHostnameSupported,
  type TeamGrant,
  type TeamGrantDraft,
  type TeamHostnameReply,
  teamJoinSecretArgs,
  teamJoinSupported,
  teamMemberName,
  teamMemberSummary,
  teamRevokeCommandInput,
  teamRoleLabel,
  teamStatusSupported,
  type TeamAction,
  type TeamStatus,
} from "./team.logic";

const UNSUPPORTED = "This Infinitus build has no team commands (needs ≥ 5bc33fa5c0).";

export function InfinitusTeamPanel() {
  const { environmentId, capability, snapshot } = useInfinitusEnvironment();
  const runCommand = useAtomCommand(infinitusEnvironment.command, { reportFailure: false });
  const runSecret = useAtomCommand(infinitusEnvironment.secret, { reportFailure: false });
  const nowMs = useRelativeTimeTick(30_000);
  /** `undefined` before the first read; null once the Mac says it is in no team. */
  const [team, setTeam] = useState<TeamStatus | null | undefined>(undefined);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<
    | TeamAction["type"]
    | "join"
    | "create"
    | "hostname"
    | "clear-hostname"
    | "grants"
    | "grant"
    | "revoke"
    | null
  >(null);
  const [joinName, setJoinName] = useState("");
  /** The code, a secret (#747): in memory only, cleared on submit, gone with the page. */
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
  /** The remote's write token, a secret (#747): in memory only, cleared on submit. */
  const [createToken, setCreateToken] = useState("");
  const [createError, setCreateError] = useState<string | null>(null);
  const [zone, setZone] = useState("");
  const [label, setLabel] = useState("");
  /** The Cloudflare API token, a secret (#747): in memory only, cleared on submit. */
  const [cfToken, setCfToken] = useState("");
  const [hostnameError, setHostnameError] = useState<string | null>(null);
  /** What the last `team-hostname` answered; the Mac has no read for it. */
  const [hostnames, setHostnames] = useState<TeamHostnameReply | null>(null);

  /** Session-control grants (#220); null before the first read or on error. */
  const [grants, setGrants] = useState<ReadonlyArray<TeamGrant> | null>(null);
  const [grantsError, setGrantsError] = useState<string | null>(null);
  const [grantFormOpen, setGrantFormOpen] = useState(false);
  const [grantAudience, setGrantAudience] = useState<TeamGrantDraft["audience"]>("team");
  const [grantKids, setGrantKids] = useState<ReadonlySet<string>>(new Set());
  const [grantCapabilities, setGrantCapabilities] = useState<ReadonlySet<string>>(new Set());
  const [grantPreauthorized, setGrantPreauthorized] = useState<ReadonlySet<string>>(new Set());
  const [grantSessions, setGrantSessions] = useState("");
  const [grantExpiresSeconds, setGrantExpiresSeconds] = useState<number | null>(null);
  const [grantError, setGrantError] = useState<string | null>(null);

  const supported =
    snapshot !== null && snapshot.available && teamStatusSupported(snapshot.commands);
  const joinSupported = snapshot !== null && teamJoinSupported(snapshot.commands);
  const createSupported = snapshot !== null && teamCreateSupported(snapshot.commands);
  const hostnameSupported = snapshot !== null && teamHostnameSupported(snapshot.commands);
  const grantsSupported = snapshot !== null && teamGrantsSupported(snapshot.commands);

  const applyStatus = useCallback((result: unknown) => {
    const parsed = parseTeamStatus(result);
    if (parsed === null) {
      setError("Infinitus answered team-status with a shape this build cannot read.");
      return;
    }
    setError(null);
    setTeam(parsed.team);
  }, []);

  /** One secret-free verb; every one but publish answers team-status. */
  const send = useCallback(
    async (action: TeamAction) => {
      if (environmentId === null) return;
      const result = await runCommand({ environmentId, input: teamCommandInput(action) });
      if (result._tag === "Failure") {
        setError(infinitusCommandFailure(result.cause).message);
        return;
      }
      if (action.type === "publish") {
        // Publish answers what it pushed; a read follows so the page shows
        // the state it changed.
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

  /** A write from a button: busy while the Mac answers. */
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

  const saveHostnames = async () => {
    if (environmentId === null) return;
    const draft = teamHostnameDraft(zone, label);
    const token = cfToken.trim();
    setCfToken("");
    if (draft === null || token.length === 0) {
      setHostnameError("Fill in the zone, the label and the Cloudflare API token.");
      return;
    }
    setBusy("hostname");
    setHostnameError(null);
    const result = await runSecret({
      environmentId,
      input: { ...teamHostnameSecretArgs(draft), secret: Redacted.make(token) },
    });
    setBusy(null);
    if (result._tag === "Failure") {
      setHostnameError(infinitusSecretFailure(result.cause));
      return;
    }
    applyHostnames(result.value.result);
  };

  const clearHostnames = async () => {
    if (environmentId === null) return;
    setBusy("clear-hostname");
    setHostnameError(null);
    const result = await runCommand({ environmentId, input: teamHostnameClearInput() });
    setBusy(null);
    if (result._tag === "Failure") {
      setHostnameError(infinitusCommandFailure(result.cause).message);
      return;
    }
    applyHostnames(result.value.result);
  };

  function applyHostnames(result: unknown) {
    const parsed = parseTeamHostnameReply(result);
    if (parsed === null) {
      setHostnameError("Infinitus answered team-hostname with a shape this build cannot read.");
      return;
    }
    setHostnames(parsed);
  }

  const refreshGrants = useCallback(async () => {
    if (environmentId === null) return;
    setBusy("grants");
    const result = await runCommand({ environmentId, input: teamGrantsCommandInput() });
    setBusy(null);
    if (result._tag === "Failure") {
      setGrantsError(infinitusCommandFailure(result.cause).message);
      return;
    }
    const parsed = parseTeamGrants(result.value.result);
    if (parsed === null) {
      setGrantsError("Infinitus answered team-grants with a shape this build cannot read.");
      return;
    }
    setGrantsError(null);
    setGrants(parsed);
  }, [environmentId, runCommand]);

  const grantsVisible = team !== null && team !== undefined && team.role !== "pending";
  useEffect(() => {
    if (!grantsSupported || !grantsVisible) return;
    void refreshGrants();
  }, [refreshGrants, grantsSupported, grantsVisible]);

  const resetGrantDraft = () => {
    setGrantAudience("team");
    setGrantKids(new Set());
    setGrantCapabilities(new Set());
    setGrantPreauthorized(new Set());
    setGrantSessions("");
    setGrantExpiresSeconds(null);
    setGrantError(null);
  };

  const toggleGrantKid = (kid: string, checked: boolean) => {
    setGrantKids((previous) => {
      const next = new Set(previous);
      if (checked) next.add(kid);
      else next.delete(kid);
      return next;
    });
  };

  const toggleGrantCapability = (capability: string, checked: boolean) => {
    setGrantCapabilities((previous) => {
      const next = new Set(previous);
      if (checked) next.add(capability);
      else next.delete(capability);
      return next;
    });
    if (!checked) {
      setGrantPreauthorized((previous) => {
        const next = new Set(previous);
        next.delete(capability);
        return next;
      });
    }
  };

  const toggleGrantPreauthorized = (capability: string, checked: boolean) => {
    setGrantPreauthorized((previous) => {
      const next = new Set(previous);
      if (checked) next.add(capability);
      else next.delete(capability);
      return next;
    });
  };

  const grantDraft: TeamGrantDraft = {
    audience: grantAudience,
    kids: [...grantKids],
    capabilities: [...grantCapabilities],
    preauthorized: [...grantPreauthorized],
    sessions: grantSessions
      .split(",")
      .map((id) => id.trim())
      .filter((id) => id.length > 0),
    expiresSeconds: grantExpiresSeconds,
  };
  const grantDraftProblem = teamGrantDraftProblem(grantDraft);

  const submitGrant = async () => {
    if (environmentId === null) return;
    const problem = teamGrantDraftProblem(grantDraft);
    if (problem !== null) {
      setGrantError(problem);
      return;
    }
    setBusy("grant");
    setGrantError(null);
    const result = await runCommand({ environmentId, input: teamGrantCommandInput(grantDraft) });
    setBusy(null);
    if (result._tag === "Failure") {
      setGrantError(infinitusCommandFailure(result.cause).message);
      return;
    }
    if (parseTeamGrant(result.value.result) === null) {
      setGrantError("Infinitus answered team-grant with a shape this build cannot read.");
      return;
    }
    setGrantFormOpen(false);
    resetGrantDraft();
    await refreshGrants();
  };

  const revokeGrant = async (id: string) => {
    if (environmentId === null) return;
    setBusy("revoke");
    setGrantsError(null);
    const result = await runCommand({ environmentId, input: teamRevokeCommandInput(id) });
    setBusy(null);
    if (result._tag === "Failure") {
      setGrantsError(infinitusCommandFailure(result.cause).message);
      return;
    }
    await refreshGrants();
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
      {team === null || team === undefined ? null : (
        <SettingsSection title="Members">
          {team.members.length === 0 ? (
            <InfinitusPanelNotice message="No roster yet." />
          ) : (
            team.members.map((member) => (
              <SettingsRow
                key={member.kid}
                title={member.name}
                description={teamMemberSummary(member, nowMs)}
              />
            ))
          )}
        </SettingsSection>
      )}
      {team === null || team === undefined || team.role === "pending" ? null : (
        <SettingsSection id="infinitus-team-grants" title="Session control">
          {!grantsSupported ? (
            <InfinitusPanelNotice message="This Infinitus build has no grant commands from here; use the Mac's Settings › Team." />
          ) : (
            <>
              {grants === null ? null : grants.length === 0 ? (
                <InfinitusPanelNotice message="Nobody can drive your sessions." />
              ) : (
                grants.map((grant) => (
                  <SettingsRow
                    key={grant.id}
                    title={`${teamGrantAudienceLabel(grant, team.members)} · ${teamGrantSessionsLabel(grant)} · ${teamGrantCapabilitiesLabel(grant)}`}
                    description={teamGrantExpiryLabel(grant, nowMs)}
                    control={
                      <Button
                        size="sm"
                        variant="outline"
                        disabled={busy !== null}
                        onClick={() => void revokeGrant(grant.id)}
                      >
                        {busy === "revoke" ? "Removing…" : "Remove"}
                      </Button>
                    }
                  />
                ))
              )}
              {grantsError === null ? null : (
                <p role="alert" className="px-3 py-2 text-[13px] text-destructive sm:px-4">
                  {grantsError}
                </p>
              )}
              {grantFormOpen ? (
                <form
                  className="flex flex-col gap-3 px-3 py-2 sm:px-4"
                  onSubmit={(event) => {
                    event.preventDefault();
                    void submitGrant();
                  }}
                >
                  <div className="flex flex-col gap-1">
                    <span className="text-[13px] font-medium">Who</span>
                    <Select
                      value={grantAudience}
                      onValueChange={(value) =>
                        setGrantAudience((value ?? "team") as TeamGrantDraft["audience"])
                      }
                    >
                      <SelectTrigger size="sm" aria-label="Who">
                        <SelectValue>
                          {grantAudience === "leaders"
                            ? "Leaders"
                            : grantAudience === "team"
                              ? "Whole team"
                              : "Only these members"}
                        </SelectValue>
                      </SelectTrigger>
                      <SelectPopup align="start" alignItemWithTrigger={false}>
                        <SelectItem value="leaders">Leaders</SelectItem>
                        <SelectItem value="team">Whole team</SelectItem>
                        <SelectItem value="members">Only these members</SelectItem>
                      </SelectPopup>
                    </Select>
                    {grantAudience === "members" ? (
                      <div className="flex flex-col gap-1 pl-2">
                        {team.members
                          .filter((member) => !member.isMe)
                          .map((member) => (
                            <label key={member.kid} className="flex items-center gap-2 text-[13px]">
                              <Checkbox
                                checked={grantKids.has(member.kid)}
                                onCheckedChange={(checked) => toggleGrantKid(member.kid, checked)}
                              />
                              {member.name}
                            </label>
                          ))}
                      </div>
                    ) : null}
                  </div>
                  <Input
                    size="sm"
                    aria-label="Session ids"
                    placeholder="Session ids, comma-separated (empty = all sessions, now and later; this app has no live list of the Mac's terminals)"
                    autoComplete="off"
                    spellCheck={false}
                    value={grantSessions}
                    disabled={busy !== null}
                    onChange={(event) => setGrantSessions(event.currentTarget.value)}
                  />
                  {TEAM_GRANT_TIERS.map((tier) => (
                    <div key={tier.name} className="flex flex-col gap-1">
                      <span className="text-[13px] font-medium">{tier.name}</span>
                      <p className="text-[12px] text-muted-foreground">
                        {tier.asks ?? "never asks"}
                      </p>
                      {tier.capabilities.map((capability) => (
                        <div key={capability} className="flex flex-col gap-0.5 pl-2">
                          <label className="flex items-center gap-2 text-[13px]">
                            <Checkbox
                              checked={grantCapabilities.has(capability)}
                              onCheckedChange={(checked) =>
                                toggleGrantCapability(capability, checked)
                              }
                            />
                            {capability}
                          </label>
                          <span className="pl-6 text-[12px] text-muted-foreground">
                            {TEAM_GRANT_MEANINGS[capability]}
                          </span>
                          {tier.asks !== null && grantCapabilities.has(capability) ? (
                            NEVER_PREAUTHORIZED.includes(capability) ? (
                              <span className="pl-6 text-[12px] text-muted-foreground">
                                always asks
                              </span>
                            ) : (
                              <label className="flex items-center gap-2 pl-6 text-[13px]">
                                <Checkbox
                                  checked={grantPreauthorized.has(capability)}
                                  onCheckedChange={(checked) =>
                                    toggleGrantPreauthorized(capability, checked)
                                  }
                                />
                                without asking
                              </label>
                            )
                          ) : null}
                        </div>
                      ))}
                    </div>
                  ))}
                  <div className="flex flex-col gap-1">
                    <span className="text-[13px] font-medium">Expires</span>
                    <Select
                      value={grantExpiresSeconds === null ? "none" : String(grantExpiresSeconds)}
                      onValueChange={(value) =>
                        setGrantExpiresSeconds(
                          value === null || value === "none" ? null : Number(value),
                        )
                      }
                    >
                      <SelectTrigger size="sm" aria-label="Expires">
                        <SelectValue>
                          {TEAM_GRANT_EXPIRY_CHOICES.find(
                            (choice) => choice.seconds === grantExpiresSeconds,
                          )?.label ?? "Until revoked"}
                        </SelectValue>
                      </SelectTrigger>
                      <SelectPopup align="start" alignItemWithTrigger={false}>
                        {TEAM_GRANT_EXPIRY_CHOICES.map((choice) => (
                          <SelectItem
                            key={choice.label}
                            value={choice.seconds === null ? "none" : String(choice.seconds)}
                          >
                            {choice.label}
                          </SelectItem>
                        ))}
                      </SelectPopup>
                    </Select>
                  </div>
                  {grantError === null ? null : (
                    <p role="alert" className="text-[13px] text-destructive">
                      {grantError}
                    </p>
                  )}
                  <div className="flex items-center justify-end gap-2">
                    <Button
                      type="button"
                      size="sm"
                      variant="ghost"
                      disabled={busy !== null}
                      onClick={() => {
                        setGrantFormOpen(false);
                        resetGrantDraft();
                      }}
                    >
                      Cancel
                    </Button>
                    <Button
                      type="submit"
                      size="sm"
                      disabled={busy !== null || grantDraftProblem !== null}
                    >
                      {busy === "grant" ? "Adding…" : "Add grant"}
                    </Button>
                  </div>
                </form>
              ) : (
                <div className="flex justify-end px-3 py-2 sm:px-4">
                  <Button
                    size="sm"
                    variant="outline"
                    disabled={busy !== null}
                    onClick={() => setGrantFormOpen(true)}
                  >
                    Add grant
                  </Button>
                </div>
              )}
              <p className="px-3 pb-2 text-[13px] text-muted-foreground sm:px-4">
                A grant lets the people named drive the sessions named — from their Mac, this app or
                infinitusctl. Stop, resume-past, delete, swap and hold ask you on the Mac first
                unless the grant says otherwise; delete always asks.
              </p>
            </>
          )}
        </SettingsSection>
      )}
      {team === null || team === undefined || team.role !== "leader" ? null : (
        <SettingsSection title="Requests">
          {team.requests.length === 0 ? (
            <InfinitusPanelNotice message="No one is asking to join." />
          ) : (
            team.requests.map((request) => (
              <SettingsRow
                key={request.kid}
                title={request.name}
                description={`${request.platform} · ${request.devices.join(", ")} · ${relativeUnix(request.at, nowMs)}`}
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
      {team === null || team === undefined || team.role !== "leader" ? null : (
        <SettingsSection id="infinitus-team-hostnames" title="Hostnames">
          {!hostnameSupported ? (
            <InfinitusPanelNotice message="This Infinitus build does not take the Cloudflare token from here; use the Mac's Settings › Team › Hostnames." />
          ) : hostnames?.configured === true ? (
            <SettingsRow
              title={`Cloudflare zone ${hostnames.zone ?? "—"} · label ${hostnames.label ?? "—"}`}
              description="Member hostnames are minted under this zone; each Mac starts its tunnel on the next fetch."
              control={
                <Button
                  size="sm"
                  variant="outline"
                  disabled={busy !== null}
                  onClick={() => void clearHostnames()}
                >
                  {busy === "clear-hostname" ? "Forgetting…" : "Forget token"}
                </Button>
              }
            />
          ) : (
            <form
              className="flex flex-col gap-2 px-3 py-2 sm:px-4"
              onSubmit={(event) => {
                event.preventDefault();
                void saveHostnames();
              }}
            >
              <Input
                size="sm"
                aria-label="Zone"
                placeholder="example.com"
                autoComplete="off"
                spellCheck={false}
                value={zone}
                disabled={busy !== null}
                onChange={(event) => setZone(event.currentTarget.value)}
              />
              <Input
                size="sm"
                aria-label="Label"
                placeholder="team"
                autoComplete="off"
                spellCheck={false}
                value={label}
                disabled={busy !== null}
                onChange={(event) => setLabel(event.currentTarget.value)}
              />
              {/* The token is a secret (#747): masked, never remembered, cleared on submit. */}
              <Input
                type="password"
                size="sm"
                autoComplete="off"
                spellCheck={false}
                aria-label="Cloudflare API token"
                placeholder="Cloudflare API token (Account: Cloudflare Tunnel Edit · Zone: DNS Edit)"
                value={cfToken}
                disabled={busy !== null}
                onChange={(event) => setCfToken(event.currentTarget.value)}
              />
              <p className="text-[13px] text-muted-foreground">
                A hostname is a Cloudflare named tunnel under your zone (name.label.zone), minted
                per member; the token is checked against the zone before the Mac keeps it. Saving
                replaces a token kept earlier.
              </p>
              <div className="flex items-center justify-end gap-2">
                <Button
                  type="button"
                  size="sm"
                  variant="ghost"
                  disabled={busy !== null}
                  onClick={() => void clearHostnames()}
                >
                  {busy === "clear-hostname" ? "Forgetting…" : "Forget token"}
                </Button>
                <Button type="submit" size="sm" disabled={busy !== null}>
                  {busy === "hostname" ? "Saving…" : "Save"}
                </Button>
              </div>
            </form>
          )}
          {hostnameError === null ? null : (
            <p role="alert" className="px-3 py-2 text-[13px] text-destructive sm:px-4">
              {hostnameError}
            </p>
          )}
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
              {/* The code is a secret (#747): masked, never remembered, cleared on submit. */}
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
            <InfinitusPanelNotice message="This Infinitus build does not take a team code from here; join from the Mac's Settings › Team." />
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
              {/* The token is a secret (#747): masked, never remembered, cleared on submit. */}
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
            <InfinitusPanelNotice message="This Infinitus build does not create a team from here; use the Mac's Settings › Team." />
          )}
        </SettingsSection>
      )}
    </SettingsPageContainer>
  );
}
