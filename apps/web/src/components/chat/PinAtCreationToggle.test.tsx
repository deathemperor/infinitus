import { act } from "react";
import { create, type ReactTestRenderer } from "react-test-renderer";
import { afterEach, beforeEach, describe, expect, it, vi } from "vite-plus/test";

import { Checkbox } from "../ui/checkbox";
import { PIN_AT_CREATION_KEY, PinAtCreationToggle } from "./PinAtCreationToggle";

/** No DOM here: the browser storage and the events the hook listens on. */
function stubWindow() {
  const store = new Map<string, string>();
  const storage = {
    clear: () => store.clear(),
    getItem: (key: string) => store.get(key) ?? null,
    key: (index: number) => [...store.keys()][index] ?? null,
    get length() {
      return store.size;
    },
    removeItem: (key: string) => void store.delete(key),
    setItem: (key: string, value: string) => void store.set(key, value),
  };
  const listeners = new Map<string, Set<(event: unknown) => void>>();
  const window = {
    localStorage: storage,
    addEventListener: (type: string, listener: (event: unknown) => void) => {
      listeners.set(type, (listeners.get(type) ?? new Set()).add(listener));
    },
    removeEventListener: (type: string, listener: (event: unknown) => void) => {
      listeners.get(type)?.delete(listener);
    },
    dispatchEvent: (event: { type: string }) => {
      for (const listener of listeners.get(event.type) ?? []) listener(event);
      return true;
    },
  };
  vi.stubGlobal("window", window);
  vi.stubGlobal("localStorage", storage);
  vi.stubGlobal(
    "CustomEvent",
    class CustomEvent<T> {
      readonly detail: T;
      constructor(
        readonly type: string,
        init: { detail: T },
      ) {
        this.detail = init.detail;
      }
    },
  );
  return storage;
}

describe("PinAtCreationToggle", () => {
  let renderer: ReactTestRenderer | null = null;
  let storage: ReturnType<typeof stubWindow>;

  beforeEach(() => {
    storage = stubWindow();
  });
  afterEach(() => {
    act(() => renderer?.unmount());
    renderer = null;
    vi.unstubAllGlobals();
  });

  const checkbox = () => renderer!.root.findByProps({ role: "checkbox" });

  it("is off until the user turns it on, and remembers the choice per browser", () => {
    act(() => {
      renderer = create(<PinAtCreationToggle />);
    });
    expect(checkbox().props["aria-checked"]).toBe(false);

    act(() => {
      renderer!.root.findByType(Checkbox).props.onCheckedChange(true);
    });
    expect(checkbox().props["aria-checked"]).toBe(true);
    expect(storage.getItem(PIN_AT_CREATION_KEY)).toBe("true");
  });

  it("starts on when the browser remembers it", () => {
    storage.setItem(PIN_AT_CREATION_KEY, "true");
    act(() => {
      renderer = create(<PinAtCreationToggle />);
    });
    expect(checkbox().props["aria-checked"]).toBe(true);
  });
});
