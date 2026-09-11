import type { CaptureItem } from "@t3tools/contracts/captures";
import * as Cause from "effect/Cause";
import * as DateTime from "effect/DateTime";
import { act } from "react";
import { create, type ReactTestRenderer } from "react-test-renderer";
import { afterEach, beforeEach, describe, expect, it, vi } from "vite-plus/test";

const { fake } = vi.hoisted(() => ({
  fake: {
    list: [] as ReadonlyArray<CaptureItem>,
    apply: vi.fn(),
    toast: vi.fn(),
    copy: vi.fn(),
  },
}));

vi.mock("~/state/captures", () => ({
  captures: { list: () => ({ label: "captures-atom" }), apply: { label: "apply-atom" } },
}));
vi.mock("~/state/query", () => ({
  useEnvironmentQuery: (atom: unknown) => ({ data: atom === null ? null : fake.list }),
}));
vi.mock("~/state/use-atom-command", () => ({
  useAtomCommand: () => (input: unknown) => fake.apply(input),
}));
vi.mock("~/hooks/useCopyToClipboard", () => ({
  writeTextToClipboard: (...args: ReadonlyArray<unknown>) => fake.copy(...args),
}));
vi.mock("../ui/toast", () => ({
  toastManager: { add: (...args: ReadonlyArray<unknown>) => fake.toast(...args) },
}));

import { ComposerCapturesMenu } from "./ComposerCapturesMenu";

const PROJECT = {
  environmentId: "env-1" as never,
  projectId: "project-1" as never,
};

const item = (id: string, text: string, doneAt: string | null = null): CaptureItem => ({
  id: id as CaptureItem["id"],
  text,
  createdAt: DateTime.makeUnsafe(`2026-09-11T10:0${id.length}:00Z`),
  doneAt: doneAt === null ? null : DateTime.makeUnsafe(doneAt),
});

function text(renderer: ReactTestRenderer): string {
  const walk = (node: unknown): string => {
    if (typeof node === "string") return node;
    if (Array.isArray(node)) return node.map(walk).join("");
    if (node !== null && typeof node === "object" && "children" in node) {
      return walk((node as { children: unknown }).children);
    }
    return "";
  };
  return walk(renderer.toJSON());
}

function byLabel(renderer: ReactTestRenderer, label: string) {
  return renderer.root.findAll(
    (node) => typeof node.type === "string" && node.props["aria-label"] === label,
  );
}

function mount(props: Partial<Parameters<typeof ComposerCapturesMenu>[0]> = {}) {
  const onSend = vi.fn(() => true);
  const onClose = vi.fn();
  let renderer: ReactTestRenderer | undefined;
  act(() => {
    renderer = create(
      <ComposerCapturesMenu
        project={PROJECT}
        focusInputKey={0}
        onSend={onSend}
        onClose={onClose}
        {...props}
      />,
    );
  });
  return { renderer: renderer!, onSend, onClose };
}

describe("ComposerCapturesMenu", () => {
  let renderer: ReactTestRenderer | null = null;

  beforeEach(() => {
    vi.stubGlobal("IS_REACT_ACT_ENVIRONMENT", true);
    fake.list = [];
    fake.apply.mockReset();
    fake.apply.mockResolvedValue({ _tag: "Success", value: {} });
    fake.toast.mockReset();
    fake.copy.mockReset();
    fake.copy.mockResolvedValue(undefined);
  });

  afterEach(() => {
    act(() => renderer?.unmount());
    renderer = null;
  });

  it("asks for a project before anything can be captured", () => {
    ({ renderer } = mount({ project: null }));
    expect(text(renderer)).toContain("Pick a project for this thread first");
    expect(byLabel(renderer, "New capture")).toHaveLength(0);
  });

  it("adds the typed text on Enter — a multi-line paste as one capture — and clears the box", async () => {
    ({ renderer } = mount());
    expect(text(renderer)).toContain("Nothing captured yet");
    const [input] = byLabel(renderer, "New capture");
    act(() => {
      input?.props.onChange({ target: { value: "  line one\nline two  " } });
    });
    await act(async () => {
      input?.props.onKeyDown({
        key: "Enter",
        shiftKey: false,
        preventDefault() {},
        stopPropagation() {},
      });
    });
    expect(fake.apply).toHaveBeenCalledWith({
      environmentId: "env-1",
      input: { projectId: "project-1", command: { type: "add", text: "line one\nline two" } },
    });
    expect(byLabel(renderer, "New capture")[0]?.props.value).toBe("");
  });

  it("draws open items above done ones and routes the row actions to apply", async () => {
    fake.list = [
      item("a", "older open"),
      item("bb", "done one", "2026-09-11T11:00:00Z"),
      item("ccc", "newest open"),
    ];
    ({ renderer } = mount());
    const rows = renderer.root.findAll(
      (node) => typeof node.type === "string" && node.props["data-capture-item"] !== undefined,
    );
    expect(rows.map((row) => row.props["data-capture-item"])).toEqual(["ccc", "a", "bb"]);
    expect(text(renderer)).toContain("Clear done (1)");

    await act(async () => {
      byLabel(renderer!, "Mark capture done")[0]?.props.onClick();
    });
    expect(fake.apply).toHaveBeenLastCalledWith(
      expect.objectContaining({
        input: { projectId: "project-1", command: { type: "setDone", id: "ccc", done: true } },
      }),
    );
    await act(async () => {
      byLabel(renderer!, "Reopen capture")[0]?.props.onClick();
    });
    expect(fake.apply).toHaveBeenLastCalledWith(
      expect.objectContaining({
        input: { projectId: "project-1", command: { type: "setDone", id: "bb", done: false } },
      }),
    );
    await act(async () => {
      byLabel(renderer!, "Remove capture")[1]?.props.onClick();
    });
    expect(fake.apply).toHaveBeenLastCalledWith(
      expect.objectContaining({
        input: { projectId: "project-1", command: { type: "remove", id: "a" } },
      }),
    );
    await act(async () => {
      byLabel(renderer!, "Clear 1 done capture")[0]?.props.onClick();
    });
    expect(fake.apply).toHaveBeenLastCalledWith(
      expect.objectContaining({
        input: { projectId: "project-1", command: { type: "clearDone" } },
      }),
    );
  });

  it("sends a capture to the composer and closes, or toasts when the composer is busy", () => {
    fake.list = [item("a", "ship it")];
    const busy = vi.fn(() => false);
    let mounted = mount({ onSend: busy });
    renderer = mounted.renderer;
    act(() => {
      byLabel(renderer!, "Send to composer")[0]?.props.onClick();
    });
    expect(busy).toHaveBeenCalledWith("ship it");
    expect(mounted.onClose).not.toHaveBeenCalled();
    expect(fake.toast).toHaveBeenCalledWith(
      expect.objectContaining({ title: "Unable to add to chat" }),
    );
    act(() => renderer?.unmount());

    mounted = mount();
    renderer = mounted.renderer;
    act(() => {
      byLabel(renderer!, "Send to composer")[0]?.props.onClick();
    });
    expect(mounted.onSend).toHaveBeenCalledWith("ship it");
    expect(mounted.onClose).toHaveBeenCalledTimes(1);
  });

  it("copies a capture and toasts the server's refusal of an add", async () => {
    fake.list = [item("a", "ship it")];
    fake.apply.mockResolvedValue({
      _tag: "Failure",
      cause: Cause.fail({ _tag: "CaptureListFull", projectId: "project-1", limit: 200 }),
    });
    ({ renderer } = mount());
    await act(async () => {
      byLabel(renderer!, "Copy capture")[0]?.props.onClick();
    });
    expect(fake.copy).toHaveBeenCalledWith("ship it", "capture");

    const [input] = byLabel(renderer, "New capture");
    act(() => {
      input?.props.onChange({ target: { value: "one more" } });
    });
    await act(async () => {
      input?.props.onKeyDown({
        key: "Enter",
        shiftKey: false,
        preventDefault() {},
        stopPropagation() {},
      });
    });
    expect(fake.toast).toHaveBeenCalledWith(
      expect.objectContaining({ description: expect.stringContaining("200 captures") }),
    );
    expect(byLabel(renderer, "New capture")[0]?.props.value).toBe("one more");
  });
});
