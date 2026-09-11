import type { InfinitusDesktopPrefs } from "@t3tools/contracts/infinitus";
import { act, StrictMode } from "react";
import { create, type ReactTestRenderer } from "react-test-renderer";
import { afterEach, describe, expect, it, vi } from "vite-plus/test";

vi.mock("../../ui/switch", () => ({
  Switch: (props: Record<string, unknown>) => <input type="checkbox" {...props} />,
}));

import { InfinitusDesktopCard, infinitusDesktopBridge } from "./InfinitusDesktopCard";

type Bridge = {
  getInfinitusDesktopPrefs: () => Promise<InfinitusDesktopPrefs>;
  setInfinitusQuitWithApp: (enabled: boolean) => Promise<InfinitusDesktopPrefs>;
};

// The unit project runs in node: give the card the one window global it reads.
function installBridge(bridge: Partial<Bridge> | undefined) {
  (globalThis as { window?: unknown }).window =
    bridge === undefined ? undefined : { desktopBridge: bridge };
}

async function render(): Promise<ReactTestRenderer> {
  let renderer: ReactTestRenderer | undefined;
  await act(async () => {
    renderer = create(
      <StrictMode>
        <InfinitusDesktopCard />
      </StrictMode>,
    );
  });
  return renderer!;
}

const text = (renderer: ReactTestRenderer) => JSON.stringify(renderer.toJSON());

afterEach(() => {
  delete (globalThis as { window?: unknown }).window;
});

describe("infinitusDesktopBridge", () => {
  it("needs both methods, so an older shell or the browser hides the card", () => {
    expect(infinitusDesktopBridge(undefined)).toBeNull();
    expect(
      infinitusDesktopBridge({
        getInfinitusDesktopPrefs: async () => ({ quitInfinitusWithApp: false }),
      }),
    ).toBeNull();
    const both = {
      getInfinitusDesktopPrefs: async () => ({ quitInfinitusWithApp: false }),
      setInfinitusQuitWithApp: async () => ({ quitInfinitusWithApp: true }),
    };
    expect(infinitusDesktopBridge(both)).not.toBeNull();
  });
});

describe("InfinitusDesktopCard", () => {
  it("renders nothing without the bridge", async () => {
    installBridge(undefined);
    const renderer = await render();
    expect(renderer.toJSON()).toBeNull();
  });

  it("reads the knob from the shell and writes it back through the bridge", async () => {
    const set = vi.fn(async (enabled: boolean) => ({ quitInfinitusWithApp: enabled }));
    installBridge({
      getInfinitusDesktopPrefs: async () => ({ quitInfinitusWithApp: false }),
      setInfinitusQuitWithApp: set,
    });
    const renderer = await render();
    expect(text(renderer)).toContain("Quit the menu-bar app with this window");
    const toggle = renderer.root.findByType("input");
    expect(toggle.props.checked).toBe(false);
    expect(toggle.props.disabled).toBe(false);
    await act(async () => {
      toggle.props.onCheckedChange(true);
    });
    expect(set).toHaveBeenCalledWith(true);
    expect(renderer.root.findByType("input").props.checked).toBe(true);
  });

  it("shows a failed write and keeps the previous value", async () => {
    installBridge({
      getInfinitusDesktopPrefs: async () => ({ quitInfinitusWithApp: true }),
      setInfinitusQuitWithApp: async () => {
        throw new Error("disk full");
      },
    });
    const renderer = await render();
    await act(async () => {
      renderer.root.findByType("input").props.onCheckedChange(false);
    });
    expect(text(renderer)).toContain("disk full");
    expect(renderer.root.findByType("input").props.checked).toBe(true);
  });
});
