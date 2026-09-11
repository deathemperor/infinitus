import type { PairingApprovalRequest } from "@t3tools/contracts/infinitusPairing";
import * as Cause from "effect/Cause";
import * as DateTime from "effect/DateTime";
import { act, StrictMode } from "react";
import { create, type ReactTestRenderer } from "react-test-renderer";
import { afterEach, beforeEach, describe, expect, it, vi } from "vite-plus/test";

const { fake } = vi.hoisted(() => ({
  fake: {
    requests: null as ReadonlyArray<PairingApprovalRequest> | null,
    decide: vi.fn(),
  },
}));

vi.mock("~/state/environments", () => ({
  usePrimaryEnvironment: () => ({ environmentId: "env-1", label: "Test environment" }),
}));
vi.mock("~/state/infinitus", () => ({
  infinitusEnvironment: {
    pairing: () => ({ label: "pairing-atom" }),
    pairingDecide: { label: "decide-atom" },
  },
}));
vi.mock("~/state/query", () => ({
  useEnvironmentQuery: (atom: unknown) => ({ data: atom === null ? null : fake.requests }),
}));
vi.mock("~/state/use-atom-command", () => ({
  useAtomCommand: () => (input: unknown) => fake.decide(input),
}));
vi.mock("../settingsLayout", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../settingsLayout")>()),
  useRelativeTimeTick: () => Date.now(),
}));

import { InfinitusPairingRequestsCard } from "./InfinitusPairingRequestsCard";

function request(overrides: Partial<PairingApprovalRequest> = {}): PairingApprovalRequest {
  return {
    id: "req-1",
    deviceName: "Titan",
    os: "iOS 26",
    remoteAddress: "192.168.1.20",
    matchCode: "AB12",
    createdAt: DateTime.makeUnsafe("2026-09-11T10:00:00Z"),
    expiresAt: DateTime.makeUnsafe("2026-09-11T10:02:00Z"),
    ...overrides,
  };
}

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

function buttons(renderer: ReactTestRenderer) {
  return renderer.root.findAll((node) => node.type === "button");
}

function mount(): ReactTestRenderer {
  let renderer: ReactTestRenderer | undefined;
  act(() => {
    renderer = create(
      <StrictMode>
        <InfinitusPairingRequestsCard />
      </StrictMode>,
    );
  });
  return renderer!;
}

describe("InfinitusPairingRequestsCard", () => {
  let renderer: ReactTestRenderer | null = null;

  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-09-11T10:00:30Z"));
    fake.requests = null;
    fake.decide.mockReset();
  });

  afterEach(() => {
    act(() => renderer?.unmount());
    renderer = null;
    vi.useRealTimers();
  });

  it("explains how a phone asks while nothing is pending", () => {
    fake.requests = [];
    renderer = mount();
    expect(text(renderer)).toContain("No phone is asking to pair");
    expect(buttons(renderer)).toHaveLength(0);
  });

  it("lists a request with its name, detail, match code, countdown and the two decisions", () => {
    fake.requests = [request()];
    renderer = mount();
    const shown = text(renderer);
    expect(shown).toContain("Titan");
    expect(shown).toContain("iOS 26 · 192.168.1.20");
    expect(shown).toContain("AB12");
    expect(shown).toContain("Expires in 1:30");
    expect(buttons(renderer).map((button) => button.props.children)).toEqual(["Approve", "Deny"]);
  });

  it("approves through the decide command and says nothing when the server took it", async () => {
    fake.requests = [request()];
    fake.decide.mockResolvedValue({ _tag: "Success", value: { decided: true } });
    renderer = mount();
    const [approve] = buttons(renderer);
    await act(async () => {
      approve?.props.onClick();
    });
    expect(fake.decide).toHaveBeenCalledWith({
      environmentId: "env-1",
      input: { id: "req-1", approve: true },
    });
    expect(renderer.root.findAll((node) => node.props.role === "alert")).toHaveLength(0);
  });

  it("denies through the same command and tells the user when the request was already gone", async () => {
    fake.requests = [request()];
    fake.decide.mockResolvedValue({ _tag: "Success", value: { decided: false } });
    renderer = mount();
    const [, deny] = buttons(renderer);
    await act(async () => {
      deny?.props.onClick();
    });
    expect(fake.decide).toHaveBeenCalledWith({
      environmentId: "env-1",
      input: { id: "req-1", approve: false },
    });
    expect(text(renderer)).toContain("That request had already expired.");
  });

  it("shows the server's reason when a decision fails", async () => {
    fake.requests = [request()];
    fake.decide.mockResolvedValue({
      _tag: "Failure",
      cause: Cause.fail({
        _tag: "PairingApprovalIssueFailed",
        message: "grant store is read-only",
      }),
    });
    renderer = mount();
    const [approve] = buttons(renderer);
    await act(async () => {
      approve?.props.onClick();
    });
    expect(text(renderer)).toContain("Could not approve that request: grant store is read-only");
  });
});
