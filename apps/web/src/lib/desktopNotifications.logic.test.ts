import { describe, expect, it } from "vite-plus/test";

import type { SidebarThreadStatus } from "../components/Sidebar.logic";
import { type SeenThread, attentionCount, threadNotifications } from "./desktopNotifications.logic";

const ALL_ON = { approval: true, input: true, held: true, failure: true, completion: true };

const thread = (
  id: string,
  status: SidebarThreadStatus,
  turn: { turnId: string; state: "running" | "completed" | "error" } | null = null,
) => ({ environmentId: "env", id, title: `Thread ${id}`, status, latestTurn: turn });

const seen = (entries: ReadonlyArray<readonly [string, SeenThread]>) => new Map(entries);

describe("threadNotifications", () => {
  it("records the first render and never posts for it", () => {
    const { requests, next } = threadNotifications(
      new Map(),
      [thread("a", "approval"), thread("b", "ready", { turnId: "t1", state: "completed" })],
      ALL_ON,
      { viewedKey: null },
    );
    expect(requests).toEqual([]);
    expect([...next.entries()]).toEqual([
      ["env:a", { status: "approval", turn: null }],
      ["env:b", { status: "ready", turn: "t1:completed" }],
    ]);
  });

  it("posts one line per thread that moved into approval, input, held or failed", () => {
    const previous = seen([
      ["env:a", { status: "working", turn: null }],
      ["env:b", { status: "working", turn: null }],
      ["env:c", { status: "working", turn: null }],
      ["env:d", { status: "working", turn: null }],
      ["env:e", { status: "approval", turn: null }],
    ]);
    const { requests } = threadNotifications(
      previous,
      [
        thread("a", "approval"),
        thread("b", "input"),
        thread("c", "held"),
        thread("d", "failed"),
        // Still in approval: no repeat.
        thread("e", "approval"),
      ],
      ALL_ON,
      { viewedKey: null },
    );
    expect(requests).toEqual([
      { environmentId: "env", threadId: "a", title: "Thread a", body: "Waiting for your approval" },
      { environmentId: "env", threadId: "b", title: "Thread b", body: "Waiting for your input" },
      { environmentId: "env", threadId: "c", title: "Thread c", body: "Held for headroom" },
      { environmentId: "env", threadId: "d", title: "Thread d", body: "The session failed" },
    ]);
  });

  it("identifies the project and scopes identical thread IDs to their environment", () => {
    const previous = seen([
      ["env:a", { status: "working", turn: null }],
      ["remote:a", { status: "working", turn: null }],
    ]);
    const threads = [
      { ...thread("a", "input"), projectTitle: "Banyan" },
      { ...thread("a", "approval"), environmentId: "remote", projectTitle: "Other project" },
    ];
    const { requests, next } = threadNotifications(previous, threads, ALL_ON, {
      viewedKey: "env:a",
    });
    expect(requests).toEqual([
      {
        environmentId: "remote",
        threadId: "a",
        title: "Other project · Thread a",
        body: "Waiting for your approval",
      },
    ]);
    expect(threadNotifications(next, threads, ALL_ON, { viewedKey: null }).requests).toEqual([]);
  });

  it("notifies again only after a thread leaves and re-enters the attention state", () => {
    const initial = seen([["env:a", { status: "working", turn: null }]]);
    const waiting = threadNotifications(initial, [thread("a", "input")], ALL_ON, {
      viewedKey: null,
    });
    expect(waiting.requests).toHaveLength(1);
    const working = threadNotifications(waiting.next, [thread("a", "working")], ALL_ON, {
      viewedKey: null,
    });
    expect(working.requests).toEqual([]);
    expect(
      threadNotifications(working.next, [thread("a", "input")], ALL_ON, { viewedKey: null })
        .requests,
    ).toHaveLength(1);
  });

  it("posts a completion only for a turn the window had not seen completed", () => {
    const previous = seen([
      ["env:a", { status: "working", turn: "t1:running" }],
      ["env:b", { status: "ready", turn: "t2:completed" }],
      ["env:c", { status: "working", turn: "t3:running" }],
    ]);
    const { requests } = threadNotifications(
      previous,
      [
        thread("a", "ready", { turnId: "t1", state: "completed" }),
        thread("b", "ready", { turnId: "t2", state: "completed" }),
        // Approval outranks the completion: one line, not two.
        thread("c", "approval", { turnId: "t3", state: "completed" }),
      ],
      ALL_ON,
      { viewedKey: null },
    );
    expect(requests).toEqual([
      { environmentId: "env", threadId: "a", title: "Thread a", body: "Finished its turn" },
      { environmentId: "env", threadId: "c", title: "Thread c", body: "Waiting for your approval" },
    ]);
  });

  it("honours each preference and stays quiet for the thread on screen", () => {
    const previous = seen([
      ["env:a", { status: "working", turn: null }],
      ["env:b", { status: "working", turn: "t1:running" }],
      ["env:c", { status: "working", turn: null }],
    ]);
    const { requests } = threadNotifications(
      previous,
      [
        thread("a", "approval"),
        thread("b", "ready", { turnId: "t1", state: "completed" }),
        thread("c", "failed"),
      ],
      { ...ALL_ON, approval: false, completion: false },
      { viewedKey: "env:c" },
    );
    expect(requests).toEqual([]);
  });
});

describe("attentionCount", () => {
  it("counts the threads waiting on the user", () => {
    expect(
      attentionCount([
        thread("a", "approval"),
        thread("b", "input"),
        thread("c", "held"),
        thread("d", "failed"),
        thread("e", "working"),
      ]),
    ).toBe(2);
  });
});
