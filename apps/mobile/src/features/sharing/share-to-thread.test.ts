import type {
  EnvironmentProject,
  EnvironmentThreadShell,
} from "@infinitus/client-runtime/state/shell";
import { EnvironmentId, ProjectId, ProviderInstanceId, ThreadId } from "@infinitus/contracts";
import { describe, expect, it } from "vite-plus/test";

import { selectShareTargetThreads } from "./share-to-thread";

const ENV = EnvironmentId.make("env-1");
const PROJECT = ProjectId.make("project-1");

function makeThread(
  input: Partial<EnvironmentThreadShell> & Pick<EnvironmentThreadShell, "id" | "title">,
): EnvironmentThreadShell {
  return {
    environmentId: ENV,
    projectId: PROJECT,
    modelSelection: { instanceId: ProviderInstanceId.make("codex"), model: "gpt-5.4" },
    runtimeMode: "full-access",
    interactionMode: "default",
    branch: null,
    worktreePath: null,
    pullRequests: [],
    latestTurn: null,
    createdAt: "2026-06-01T00:00:00.000Z",
    updatedAt: "2026-06-01T00:00:00.000Z",
    archivedAt: null,
    session: null,
    latestUserMessageAt: null,
    hasPendingApprovals: false,
    hasPendingUserInput: false,
    hasActionableProposedPlan: false,
    settledOverride: null,
    settledAt: null,
    ...input,
  };
}

const projects: ReadonlyArray<EnvironmentProject> = [
  {
    environmentId: ENV,
    id: PROJECT,
    title: "Limitless",
    workspaceRoot: "/repo/limitless",
    faviconPath: null,
  } as EnvironmentProject,
];

describe("selectShareTargetThreads", () => {
  it("lists unarchived threads newest first with their project title", () => {
    const rows = selectShareTargetThreads({
      projects,
      query: "",
      threads: [
        makeThread({ id: ThreadId.make("old"), title: "Old", updatedAt: "2026-06-01T00:00:00Z" }),
        makeThread({ id: ThreadId.make("new"), title: "New", updatedAt: "2026-06-03T00:00:00Z" }),
        makeThread({
          id: ThreadId.make("gone"),
          title: "Archived",
          archivedAt: "2026-06-02T00:00:00Z",
        }),
      ],
    });
    expect(rows.map((row) => row.thread.id)).toEqual(["new", "old"]);
    expect(rows[0]?.projectTitle).toBe("Limitless");
  });

  it("matches the query against thread and project titles", () => {
    const threads = [
      makeThread({ id: ThreadId.make("a"), title: "Fix login" }),
      makeThread({
        id: ThreadId.make("b"),
        title: "Other",
        projectId: ProjectId.make("unknown"),
      }),
    ];
    expect(
      selectShareTargetThreads({ projects, query: "LOGIN", threads }).map((row) => row.thread.id),
    ).toEqual(["a"]);
    expect(
      selectShareTargetThreads({ projects, query: "limit", threads }).map((row) => row.thread.id),
    ).toEqual(["a"]);
    expect(selectShareTargetThreads({ projects, query: "", threads })[1]?.projectTitle).toBeNull();
  });
});
