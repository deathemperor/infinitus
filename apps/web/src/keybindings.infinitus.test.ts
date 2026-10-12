// The fork's keybinding cases, beside upstream's `keybindings.test.ts`.
import { assert, describe, it } from "vite-plus/test";
import {
  compileResolvedKeybindingsConfig,
  mergeWithDefaultKeybindings,
} from "@infinitus/shared/keybindings";

import { resolveShortcutCommand, type ShortcutEventLike } from "./keybindings";

function event(overrides: Partial<ShortcutEventLike> = {}): ShortcutEventLike {
  return {
    key: "j",
    metaKey: false,
    ctrlKey: false,
    shiftKey: false,
    altKey: false,
    ...overrides,
  };
}

describe("second default keys", () => {
  it("adds a newly shipped default key to a config that snapshotted the old one", () => {
    // A config snapshotted when chat.new had only `mod+n` already names the
    // command. Keying the override on the command alone dropped the new
    // default, so `mod+shift+o` silently never existed.
    const bindings = mergeWithDefaultKeybindings(
      compileResolvedKeybindingsConfig([
        { key: "mod+n", command: "chat.new", when: "!terminalFocus" },
      ]),
    );
    for (const [key, shiftKey] of [
      ["n", false],
      ["o", true],
    ] as const) {
      assert.strictEqual(
        resolveShortcutCommand(event({ key, metaKey: true, shiftKey }), bindings, {
          platform: "MacIntel",
        }),
        "chat.new",
      );
    }
  });

  it("still lets a real remap of the command suppress the shipped defaults", () => {
    const bindings = mergeWithDefaultKeybindings(
      compileResolvedKeybindingsConfig([{ key: "mod+alt+x", command: "chat.new" }]),
    );
    assert.strictEqual(
      resolveShortcutCommand(event({ key: "x", metaKey: true, altKey: true }), bindings, {
        platform: "MacIntel",
      }),
      "chat.new",
    );
    for (const [key, shiftKey] of [
      ["n", false],
      ["o", true],
    ] as const) {
      assert.isNull(
        resolveShortcutCommand(event({ key, metaKey: true, shiftKey }), bindings, {
          platform: "MacIntel",
        }),
      );
    }
  });
});
