import type { InfinitusForkTunnel, InfinitusSnapshot } from "@t3tools/contracts/infinitus";
import * as DateTime from "effect/DateTime";
import { act, StrictMode } from "react";
import { create, type ReactTestRenderer } from "react-test-renderer";
import { afterEach, beforeEach, describe, expect, it, vi } from "vite-plus/test";

const { fake } = vi.hoisted(() => ({
  fake: {
    snapshot: null as InfinitusSnapshot | null,
    create: vi.fn(),
    revoke: vi.fn(),
    loopback: true,
  },
}));

vi.mock("./InfinitusPrefsPanel", () => ({
  useInfinitusEnvironment: () => ({
    environmentId: "env-1",
    capability: true,
    snapshot: fake.snapshot,
  }),
}));
vi.mock("~/environments/primary", () => ({
  createServerPairingCredential: (...args: Array<unknown>) => fake.create(...args),
  revokeServerPairingLink: (...args: Array<unknown>) => fake.revoke(...args),
}));
vi.mock("~/environments/primary/target", () => ({
  isLoopbackHostname: () => fake.loopback,
}));
vi.mock("../settingsLayout", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../settingsLayout")>()),
  useRelativeTimeTick: () => Date.now(),
}));

import { InfinitusPairPhoneCard } from "./InfinitusPairPhoneCard";

const TUNNEL_URL = "https://example-words.trycloudflare.com";

function snapshot(forkTunnel: InfinitusForkTunnel | undefined): InfinitusSnapshot {
  return {
    available: true,
    status: {
      version: "0.5.0",
      sha: "3bdc03cca",
      socket: "/tmp/infinitus.sock",
      badge: "none",
      playground: false,
      signInRunning: false,
      engines: {},
      ...(forkTunnel === undefined ? {} : { forkTunnel }),
    },
    fleets: [],
    sessions: [],
    commands: [],
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
        <InfinitusPairPhoneCard />
      </StrictMode>,
    );
  });
  return renderer!;
}

describe("InfinitusPairPhoneCard", () => {
  let renderer: ReactTestRenderer | null = null;

  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date("2026-09-10T12:00:00Z"));
    fake.snapshot = null;
    fake.loopback = true;
    fake.create.mockReset();
    fake.revoke.mockReset();
    fake.revoke.mockResolvedValue(undefined);
  });

  afterEach(() => {
    act(() => renderer?.unmount());
    renderer = null;
    vi.useRealTimers();
  });

  it("tells a loopback page with the tunnel off to turn the tunnel on, with no QR", () => {
    fake.snapshot = snapshot({ enabled: false, port: 3773, state: "off" });
    renderer = mount();

    expect(text(renderer)).toContain("Turn on the Cloudflare quick tunnel");
    expect(buttons(renderer)).toHaveLength(0);
    expect(renderer.root.findAll((node) => node.type === "svg")).toHaveLength(0);
  });

  it("mints a link on demand while the tunnel is up and draws the QR with the tunnel host", async () => {
    fake.snapshot = snapshot({ enabled: true, port: 3773, state: "up", url: TUNNEL_URL });
    fake.create.mockResolvedValue({
      id: "link-1",
      credential: "fixture-token",
      expiresAt: DateTime.makeUnsafe(Date.now() + 5 * 60_000),
    });
    renderer = mount();

    expect(fake.create).not.toHaveBeenCalled();
    const [show] = buttons(renderer);
    expect(text(renderer)).toContain("Show QR");
    await act(async () => {
      show?.props.onClick();
    });

    expect(fake.create).toHaveBeenCalledWith({ label: "Infinitus phone" });
    const svg = renderer.root.findAll((node) => node.type === "svg");
    expect(svg).toHaveLength(1);
    expect(text(renderer)).toContain("Expires in 5:00");
    expect(text(renderer)).toContain("Copy link");
    // The token never lands in the DOM as text — only inside the QR.
    expect(text(renderer)).not.toContain("fixture-token");
  });

  it("revokes the link it replaces when a new one is minted", async () => {
    fake.snapshot = snapshot({ enabled: true, port: 3773, state: "up", url: TUNNEL_URL });
    fake.create
      .mockResolvedValueOnce({
        id: "link-1",
        credential: "fixture-token-1",
        expiresAt: DateTime.makeUnsafe(Date.now() + 5 * 60_000),
      })
      .mockResolvedValueOnce({
        id: "link-2",
        credential: "fixture-token-2",
        expiresAt: DateTime.makeUnsafe(Date.now() + 5 * 60_000),
      });
    renderer = mount();

    await act(async () => {
      buttons(renderer!)[0]?.props.onClick();
    });
    const fresh = buttons(renderer).find(
      (button) => text({ toJSON: () => button.children } as never) === "New link",
    );
    await act(async () => {
      fresh?.props.onClick();
    });

    expect(fake.create).toHaveBeenCalledTimes(2);
    expect(fake.revoke).toHaveBeenCalledWith("link-1");
  });

  it("explains an older build without the tunnel", () => {
    fake.snapshot = snapshot(undefined);
    renderer = mount();

    expect(text(renderer)).toContain("no fork tunnel");
    expect(buttons(renderer)).toHaveLength(0);
  });

  it("offers a network-only link from a LAN page while the tunnel is off", () => {
    fake.loopback = false;
    vi.stubGlobal("window", {
      location: { hostname: "192.168.1.20", origin: "http://192.168.1.20:3773" },
    });
    fake.snapshot = snapshot({ enabled: false, port: 3773, state: "off" });
    try {
      renderer = mount();

      expect(text(renderer)).toContain("only works for phones on your network");
      expect(text(renderer)).toContain("Show QR");
    } finally {
      vi.unstubAllGlobals();
    }
  });
});
