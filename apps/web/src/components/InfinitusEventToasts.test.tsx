import { EnvironmentId } from "@t3tools/contracts";
import type { InfinitusSnapshot } from "@t3tools/contracts/infinitus";
import { act } from "react";
import { create, type ReactTestRenderer } from "react-test-renderer";
import { beforeEach, describe, expect, it, vi } from "vite-plus/test";

const environmentId = EnvironmentId.make("test-environment");

const testState = vi.hoisted(() => ({
  snapshot: null as InfinitusSnapshot | null,
  capability: true as boolean | undefined,
  addToast: vi.fn(),
  command: vi.fn(),
}));

vi.mock("../components/ui/toast", () => ({
  // Read at call time: `beforeEach` swaps the spy out.
  toastManager: { add: (...args: ReadonlyArray<unknown>) => testState.addToast(...args) },
  stackedThreadToast: (options: unknown) => options,
}));
vi.mock("../state/environments", () => ({
  usePrimaryEnvironment: () => ({
    environmentId: "test-environment",
    label: "Test environment",
    serverConfig: { environment: { capabilities: { infinitus: testState.capability } } },
  }),
}));
vi.mock("../state/infinitus", () => ({
  infinitusEnvironment: {
    snapshot: () => ({ label: "snapshot-atom" }),
    command: { label: "command-atom" },
  },
}));
vi.mock("../state/query", () => ({
  useEnvironmentQuery: (atom: unknown) => ({
    data: atom === null ? null : testState.snapshot,
    error: null,
    isPending: false,
    isSuccess: true,
    refresh: vi.fn(),
  }),
}));
vi.mock("../state/use-atom-command", () => ({ useAtomCommand: () => testState.command }));

import { InfinitusEventToasts } from "./InfinitusEventToasts";

const event = (id: string, icon: string, text: string) => ({
  id,
  at: "2026-09-10T08:00:00Z",
  icon,
  text,
});
const switched = (id: string) =>
  event(id, "arrow.triangle.2.circlepath", "switched one@example.com → two@example.com");
const exhausted = (id: string) => event(id, "battery.0percent", "all exhausted");
const waiting = (id: string) =>
  event(id, "hand.raised", "headless session 4243 is waiting for an answer");

const snapshotWith = (events: ReadonlyArray<ReturnType<typeof event>>): InfinitusSnapshot => ({
  available: true,
  fleets: [],
  sessions: [],
  commands: [],
  events,
});

async function mount(): Promise<ReactTestRenderer> {
  let renderer!: ReactTestRenderer;
  await act(async () => {
    renderer = create(<InfinitusEventToasts />);
  });
  return renderer;
}

async function deliver(renderer: ReactTestRenderer, snapshot: InfinitusSnapshot): Promise<void> {
  testState.snapshot = snapshot;
  await act(async () => {
    renderer.update(<InfinitusEventToasts />);
  });
}

beforeEach(() => {
  vi.stubGlobal("IS_REACT_ACT_ENVIRONMENT", true);
  testState.snapshot = null;
  testState.capability = true;
  testState.addToast = vi.fn();
  testState.command = vi.fn().mockResolvedValue({ _tag: "Success", value: {} });
});

describe("InfinitusEventToasts", () => {
  it("never replays the first snapshot, then toasts each new event once", async () => {
    testState.snapshot = snapshotWith([switched("a")]);
    const renderer = await mount();
    expect(testState.addToast).not.toHaveBeenCalled();

    await deliver(renderer, snapshotWith([switched("a"), switched("b")]));
    expect(testState.addToast).toHaveBeenCalledTimes(1);
    expect(testState.addToast).toHaveBeenLastCalledWith(
      expect.objectContaining({ type: "info", title: "Switched accounts" }),
    );

    // The same delta delivered again, and an identical re-render: nothing new.
    await deliver(renderer, snapshotWith([switched("a"), switched("b")]));
    await deliver(renderer, snapshotWith([switched("b")]));
    expect(testState.addToast).toHaveBeenCalledTimes(1);
    renderer.unmount();
  });

  it("waits for a real snapshot before priming, so the first delta after loading is history", async () => {
    testState.snapshot = null;
    const renderer = await mount();
    await deliver(renderer, snapshotWith([exhausted("a")]));
    expect(testState.addToast).not.toHaveBeenCalled();
    await deliver(renderer, snapshotWith([exhausted("b")]));
    expect(testState.addToast).toHaveBeenCalledTimes(1);
    renderer.unmount();
  });

  it("drops the noise and collapses a line the app re-emits unchanged", async () => {
    testState.snapshot = snapshotWith([]);
    const renderer = await mount();
    await deliver(
      renderer,
      snapshotWith([
        event("p1", "clock.arrow.circlepath", "poll"),
        event("n1", "hand.raised", "no switch — already consuming soonest"),
        exhausted("x1"),
      ]),
    );
    await deliver(renderer, snapshotWith([exhausted("x2")]));
    expect(testState.addToast).toHaveBeenCalledTimes(1);
    expect(testState.addToast).toHaveBeenLastCalledWith(
      expect.objectContaining({ type: "error", title: "All accounts exhausted" }),
    );

    await deliver(renderer, snapshotWith([switched("s1"), exhausted("x3")]));
    expect(testState.addToast).toHaveBeenCalledTimes(3);
    renderer.unmount();
  });

  it("offers Show on a waiting session, which opens the pop-out on a host without show session", async () => {
    testState.snapshot = snapshotWith([]);
    const renderer = await mount();
    await deliver(renderer, snapshotWith([waiting("w1")]));
    expect(testState.addToast).toHaveBeenCalledTimes(1);
    const toast = testState.addToast.mock.calls[0]![0] as {
      type: string;
      actionProps: { children: string; onClick: () => void };
    };
    expect(toast.type).toBe("warning");
    expect(toast.actionProps.children).toBe("Show");

    toast.actionProps.onClick();
    expect(testState.command).toHaveBeenCalledWith({
      environmentId,
      input: { command: "show", args: ["popout"], options: {} },
    });
    renderer.unmount();
  });

  it("Show opens the waiting session's own window when the host's show takes a session (#612)", async () => {
    const showSession = {
      name: "show",
      args: [
        "popout|settings|wall|workspace [sidebar|thread|composer|draft|switcher]|session <pid|name>",
      ],
      options: [],
      effect: "write" as const,
      summary: "",
      replyShape: "{shown}",
    };
    testState.snapshot = { ...snapshotWith([]), commands: [showSession] };
    const renderer = await mount();
    await deliver(renderer, { ...snapshotWith([waiting("w1")]), commands: [showSession] });
    const toast = testState.addToast.mock.calls[0]![0] as {
      actionProps: { onClick: () => void };
    };
    toast.actionProps.onClick();
    expect(testState.command).toHaveBeenCalledWith({
      environmentId,
      input: { command: "show", args: ["session", "4243"], options: {} },
    });
    renderer.unmount();
  });

  it("does nothing without the capability", async () => {
    testState.capability = false;
    testState.snapshot = snapshotWith([]);
    const renderer = await mount();
    await deliver(renderer, snapshotWith([switched("a")]));
    expect(testState.addToast).not.toHaveBeenCalled();
    renderer.unmount();
  });
});
