/**
 * Settings › Infinitus › Team (#747): the team this Mac is in, read over the
 * control socket's `team-status`, with Fetch now / Publish now and, for a
 * leader, the pending requests' Approve / Decline. With no team the page
 * offers Join: this Mac's roster name as the argument, the team code or
 * invite link on `infinitus.secret` (`type="password"`, never remembered,
 * cleared on submit; the Mac's own error verbatim, the code never in it).
 *
 * @module InfinitusTeamPanel
 */
import * as Redacted from "effect/Redacted";
import { useCallback, useEffect, useState } from "react";

import { infinitusEnvironment } from "~/state/infinitus";
import { useAtomCommand } from "~/state/use-atom-command";

import { Button } from "../../ui/button";
import { Input } from "../../ui/input";
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
  parseTeamStatus,
  relativeUnix,
  teamCommandInput,
  teamJoinSecretArgs,
  teamJoinSupported,
  teamMemberName,
  teamMemberSummary,
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
  const [busy, setBusy] = useState<TeamAction["type"] | "join" | null>(null);
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
    </SettingsPageContainer>
  );
}
