import { scopeProjectRef } from "@t3tools/client-runtime/environment";
import {
  nudgeOutcome,
  type SessionRowModel,
} from "@t3tools/client-runtime/state/infinitusSessions";
import {
  findProjectByPath,
  inferProjectTitleFromPath,
} from "@t3tools/client-runtime/state/projects";
import { squashAtomCommandFailure } from "@t3tools/client-runtime/state/runtime";
import { CommandId, type EnvironmentId, ProjectId, type ThreadId } from "@t3tools/contracts";
import { useState } from "react";
import { ActivityIndicator, Pressable, View } from "react-native";

import { SymbolView } from "../../components/AppSymbol";
import { AppText as Text } from "../../components/AppText";
import { ControlPillMenu } from "../../components/ControlPill";
import { StatusPill } from "../../components/StatusPill";
import { cn } from "../../lib/cn";
import { uuidv4 } from "../../lib/uuid";
import { agentSessionImport } from "../../state/agentSessions";
import { readProjects, waitForProject } from "../../state/entities";
import { infinitusEnvironment } from "../../state/infinitus";
import { projectEnvironment } from "../../state/projects";
import { useAtomCommand } from "../../state/use-atom-command";
import { commandFailureMessage } from "../accounts/accountsRoute.logic";
import { SettingsSection } from "../settings/components/SettingsSection";
import {
  type MacSessionsView,
  MOVED_NOTE,
  moveOutcome,
  sessionChoiceCommand,
  sessionMenuActions,
  sessionMenuChoice,
  sessionRowDetail,
} from "./sessions.logic";

const STATE_DOT: Record<SessionRowModel["state"], string> = {
  waiting: "bg-warning",
  working: "bg-primary",
  idle: "bg-subtle-strong",
  shell: "bg-subtle-strong",
  unknown: "bg-subtle",
};

/** One Mac's live Claude Code sessions (the snapshot's `sessions`), the ones
    needing a person first. A row's context menu offers what this build's
    manifest lists: open its chat window on the Mac (`show session <pid>`),
    the resume nudge by hand (`nudge <pid>`), and its permission mode
    (`session-mode`). "Move to a thread" (#648) is the server's
    `agentSessions.import` of the row's transcript into the project rooted at
    its cwd (created when missing); the terminal session is never touched. */
export function InfinitusSessions(props: {
  readonly environmentId: EnvironmentId;
  readonly view: MacSessionsView;
  readonly onOpenThread: (threadId: ThreadId) => void;
}) {
  const { environmentId, view, onOpenThread } = props;
  return (
    <SettingsSection title="Sessions" card>
      {view.attentionCount > 0 ? (
        <View className="border-b border-separator px-4 py-2">
          <StatusPill
            size="compact"
            label={`${view.attentionCount} need you`}
            pillClassName="bg-warning"
            textClassName="text-warning-foreground"
          />
        </View>
      ) : null}
      {view.rows.map((row, index) => (
        <SessionRow
          key={row.pid}
          environmentId={environmentId}
          row={row}
          view={view}
          last={index === view.rows.length - 1}
          onOpenThread={onOpenThread}
        />
      ))}
    </SettingsSection>
  );
}

function SessionRow(props: {
  readonly environmentId: EnvironmentId;
  readonly row: SessionRowModel;
  readonly view: MacSessionsView;
  readonly last: boolean;
  readonly onOpenThread: (threadId: ThreadId) => void;
}) {
  const { environmentId, row } = props;
  const run = useAtomCommand(infinitusEnvironment.command, { reportFailure: false });
  const createProject = useAtomCommand(projectEnvironment.create, { reportFailure: false });
  const importThreads = useAtomCommand(agentSessionImport, { reportFailure: false });
  const [busy, setBusy] = useState(false);
  const [note, setNote] = useState<string | null>(null);
  /** Set once this row's transcript is a thread; moving again is safe (the
      import finds the thread it made). */
  const [moved, setMoved] = useState(false);

  /** The project rooted at the row's cwd, created when missing and awaited in
      the client store so the import that follows can find it. */
  const ensureProject = async (): Promise<ProjectId> => {
    const existing = findProjectByPath(
      readProjects().filter((project) => project.environmentId === environmentId),
      row.cwd,
    );
    if (existing !== undefined) return existing.id;
    const projectId = ProjectId.make(uuidv4());
    const result = await createProject({
      environmentId,
      input: {
        projectId,
        commandId: CommandId.make(`infinitus:sessions:move:${projectId}`),
        title: inferProjectTitleFromPath(row.cwd),
        workspaceRoot: row.cwd,
        createWorkspaceRootIfMissing: false,
        defaultModelSelection: null,
      },
    });
    if (result._tag !== "Success") throw squashAtomCommandFailure(result);
    await waitForProject(scopeProjectRef(environmentId, projectId));
    return projectId;
  };

  const move = async (sessionId: string) => {
    try {
      const projectId = await ensureProject();
      const result = await importThreads({
        environmentId,
        input: { projectId, expectedWorkspaceRoot: row.cwd, providerSessionIds: [sessionId] },
      });
      if (result._tag !== "Success") throw squashAtomCommandFailure(result);
      const outcome = moveOutcome(result.value, sessionId);
      if (outcome.threadId === null) {
        setNote(outcome.reason);
        return;
      }
      setMoved(true);
      props.onOpenThread(outcome.threadId);
    } catch (error) {
      setNote(
        error instanceof Error && error.message.trim() !== "" ? error.message : "The move failed.",
      );
    }
  };

  const choose = async (id: string) => {
    const choice = sessionMenuChoice(id);
    if (choice === null) return;
    if (choice.kind === "move") {
      if (row.sessionId === null || busy) return;
      setBusy(true);
      setNote(null);
      await move(row.sessionId);
      setBusy(false);
      return;
    }
    const input = sessionChoiceCommand(row, choice);
    if (input === null) return;
    setBusy(true);
    setNote(null);
    const result = await run({ environmentId, input });
    setBusy(false);
    if (result._tag !== "Success") {
      setNote(commandFailureMessage(result.cause));
      return;
    }
    if (choice.kind === "nudge") {
      const outcome = nudgeOutcome(result.value.result);
      if (!outcome.nudged) setNote(outcome.reason ?? "The session was not nudged.");
    }
  };

  const actions = sessionMenuActions(row, props.view.actions);
  const content = (
    <View className={cn("gap-1 px-4 py-3", props.last ? null : "border-b border-separator")}>
      <View className="flex-row items-center gap-2">
        <View className={cn("size-2 rounded-full", STATE_DOT[row.state])} />
        <Text className="shrink text-base font-t3-medium text-foreground" numberOfLines={1}>
          {row.title}
        </Text>
        <View className="flex-1" />
        {busy ? (
          <ActivityIndicator size="small" />
        ) : actions.length > 0 ? (
          <SymbolView
            name="ellipsis.circle"
            size={18}
            tintColorClassName="accent-icon"
            type="monochrome"
          />
        ) : null}
      </View>
      <Text className="text-xs text-foreground-muted" numberOfLines={1}>
        {sessionRowDetail(row)}
      </Text>
      {row.needs.map((need) => (
        <Text key={need} className="text-xs text-warning-foreground">
          {need}
        </Text>
      ))}
      {moved ? <Text className="text-xs text-foreground-muted">{MOVED_NOTE}</Text> : null}
      {note ? <Text className="text-xs text-danger-foreground">{note}</Text> : null}
    </View>
  );

  if (actions.length === 0) return content;
  return (
    <ControlPillMenu
      title={row.title}
      actions={[...actions]}
      onPressAction={({ nativeEvent }) => void choose(nativeEvent.event)}
      accessibilityRole="button"
      accessibilityLabel={`${row.title} actions`}
    >
      <Pressable className="active:opacity-70">{content}</Pressable>
    </ControlPillMenu>
  );
}
