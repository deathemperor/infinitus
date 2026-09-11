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
    exposure: null as { mode: string; endpointUrl: string | null } | null,
    lan: [] as ReadonlyArray<string>,
  },
}));

vi.mock("./InfinitusPrefsPanel", () => ({
  useInfinitusEnvironment: () => ({
    environmentId: "env-1",
    capability: true,
    snapshot: fake.snapshot,
    serverLanOrigins: fake.lan,
  }),
}));
vi.mock("~/environments/primary", () => ({
  createServerPairingCredential: (...args: Array<unknown>) => fake.create(...args),
  revokeServerPairingLink: (...args: Array<unknown>) => fake.revoke(...args),
}));
vi.mock("~/environments/primary/target", () => ({
  isLoopbackHostname: () => fake.loopback,
}));
vi.mock("~/state/desktopNetworkAccess", () => ({ desktopNetworkAccessStateAtom: "atom" }));
vi.mock("~/state/query", () => ({
  useEnvironmentQuery: (atom: unknown) => ({
    data: atom === null || fake.exposure === null ? null : { serverExposureState: fake.exposure },
  }),
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
    fake.exposure = null;
    fake.lan = [];
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
    expect(text(renderer)).toContain("Scan with the Camera app on a phone that has Infinitus");
    expect(text(renderer)).toContain("The Camera app opens a web page instead");
    expect(text(renderer)).not.toContain("Scan with the Infinitus app");
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

      expect(text(renderer)).toContain("only works for phones on your Wi‑Fi");
      expect(text(renderer)).toContain("Show QR");
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it("points a loopback page at Network access when the desktop server is local-only", () => {
    vi.stubGlobal("window", { location: { hostname: "127.0.0.1" }, desktopBridge: {} });
    fake.exposure = { mode: "local-only", endpointUrl: null };
    fake.snapshot = snapshot({ enabled: false, port: 3773, state: "off" });
    try {
      renderer = mount();

      expect(text(renderer)).toContain("Network access is on under Settings › Connections");
      expect(buttons(renderer)).toHaveLength(0);
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it("encodes the desktop server's LAN address, and reveals host and code for typing on request", async () => {
    vi.stubGlobal("window", { location: { hostname: "127.0.0.1" }, desktopBridge: {} });
    fake.exposure = { mode: "network-accessible", endpointUrl: "http://192.168.1.20:3773" };
    fake.snapshot = snapshot({ enabled: false, port: 3773, state: "off" });
    fake.create.mockResolvedValue({
      id: "link-1",
      credential: "fixture-token",
      expiresAt: DateTime.makeUnsafe(Date.now() + 5 * 60_000),
    });
    try {
      renderer = mount();
      const [show] = buttons(renderer);
      await act(async () => {
        show?.props.onClick();
      });

      const svg = renderer.root.findAll((node) => node.type === "svg");
      expect(svg).toHaveLength(1);
      expect(text(renderer)).not.toContain("fixture-token");
      const reveal = buttons(renderer).find((node) => text0(node) === "Type it instead");
      act(() => reveal?.props.onClick());
      expect(text(renderer)).toContain("host 192.168.1.20:3773, code fixture-token.");
    } finally {
      vi.unstubAllGlobals();
    }
  });

  it("lets the user pick the same network over the tunnel when both reach the server", async () => {
    vi.stubGlobal("window", { location: { hostname: "127.0.0.1" }, desktopBridge: {} });
    fake.exposure = { mode: "network-accessible", endpointUrl: "http://192.168.1.20:3773" };
    fake.snapshot = snapshot({ enabled: true, port: 3773, state: "up", url: TUNNEL_URL });
    fake.create.mockResolvedValue({
      id: "link-1",
      credential: "fixture-token",
      expiresAt: DateTime.makeUnsafe(Date.now() + 5 * 60_000),
    });
    try {
      renderer = mount();
      expect(text(renderer)).toContain("Pair overInternetSame Wi‑Fi");
      expect(text(renderer)).not.toContain("only works for phones on your Wi‑Fi");

      const sameNetwork = buttons(renderer).find((node) => text0(node) === "Same Wi‑Fi");
      act(() => sameNetwork?.props.onClick());
      expect(text(renderer)).toContain("only works for phones on your Wi‑Fi");

      const show = buttons(renderer).find((node) => text0(node) === "Show QR");
      await act(async () => {
        show?.props.onClick();
      });
      const svg = renderer.root.findAll((node) => node.type === "svg");
      expect(svg[0]?.props.role ?? svg).toBeDefined();
      const qr = renderer.root.findAll((node) => node.props?.value?.startsWith?.("http"));
      expect(qr[0]?.props.value).toBe(
        "https://infinitus.run/pair#token=fixture-token&for=phone&to=http%3A%2F%2F192.168.1.20%3A3773",
      );
    } finally {
      vi.unstubAllGlobals();
    }
  });
  it("encodes the address the server reports when there is no desktop bridge and no tunnel (#651)", async () => {
    vi.stubGlobal("window", { location: { hostname: "127.0.0.1" } });
    fake.lan = ["http://192.168.1.20:3773", "http://10.0.0.7:3773"];
    fake.snapshot = snapshot({ enabled: false, port: 3773, state: "off" });
    fake.create.mockResolvedValue({
      id: "link-1",
      credential: "fixture-token",
      expiresAt: DateTime.makeUnsafe(Date.now() + 5 * 60_000),
    });
    try {
      renderer = mount();
      expect(text(renderer)).toContain("only works for phones on your Wi‑Fi");
      expect(text(renderer)).not.toContain("Network access is on under Settings › Connections");
      const show = buttons(renderer).find((node) => text0(node) === "Show QR");
      await act(async () => {
        show?.props.onClick();
      });
      const qr = renderer.root.findAll((node) => node.props?.value?.startsWith?.("http"));
      expect(qr[0]?.props.value).toMatch(
        /^https:\/\/infinitus\.run\/pair#token=fixture-token&for=phone&to=http%3A%2F%2F192\.168\.1\.20%3A3773$/,
      );
    } finally {
      vi.unstubAllGlobals();
    }
  });
});

function text0(node: { children: ReadonlyArray<unknown> }): string {
  return node.children.map((child) => (typeof child === "string" ? child : "")).join("");
}
