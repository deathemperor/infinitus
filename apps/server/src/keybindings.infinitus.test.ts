// The fork's startup-sync cases (the retired `mod+[` / `mod+]` defaults of
// #840 giving way to upstream's history keys), beside upstream's
// `keybindings.test.ts`; the fixtures are copies of that file's.
import { KeybindingCommand, KeybindingRule, KeybindingsConfig } from "@infinitus/contracts";
import * as NodeServices from "@effect/platform-node/NodeServices";
import { assert, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Layer from "effect/Layer";
import * as Path from "effect/Path";
import * as Schema from "effect/Schema";
import * as ServerConfig from "./config.ts";
import * as Keybindings from "./keybindings.ts";

const KeybindingsConfigJson = Schema.fromJsonString(KeybindingsConfig);
const encodeKeybindingsConfigJson = Schema.encodeEffect(KeybindingsConfigJson);
const decodeKeybindingsConfigJson = Schema.decodeUnknownEffect(KeybindingsConfigJson);
const layerKeybindings = () => {
  return Keybindings.layer.pipe(
    Layer.provideMerge(
      Layer.fresh(
        ServerConfig.layerTest(process.cwd(), {
          prefix: "t3code-keybindings-test-",
        }),
      ),
    ),
  );
};

const writeKeybindingsConfig = (configPath: string, rules: readonly KeybindingRule[]) =>
  Effect.gen(function* () {
    const fileSystem = yield* FileSystem.FileSystem;
    const path = yield* Path.Path;
    const encoded = yield* encodeKeybindingsConfigJson(rules);
    yield* fileSystem.makeDirectory(path.dirname(configPath), { recursive: true });
    yield* fileSystem.writeFileString(configPath, encoded);
  });

const readKeybindingsConfig = (configPath: string) =>
  Effect.gen(function* () {
    const fileSystem = yield* FileSystem.FileSystem;
    const rawConfig = yield* fileSystem.readFileString(configPath);
    return yield* decodeKeybindingsConfigJson(rawConfig);
  });

it.layer(NodeServices.layer)("keybindings startup sync", (it) => {
  it.effect("drops the fork's retired bracket rules so upstream's history keys apply", () =>
    Effect.gen(function* () {
      const { keybindingsConfigPath } = yield* ServerConfig.ServerConfig;
      // What the startup sync persisted while #840 shipped these defaults.
      yield* writeKeybindingsConfig(keybindingsConfigPath, [
        { key: "mod+shift+[", command: "thread.previous" },
        { key: "mod+[", command: "thread.previous" },
        { key: "mod+]", command: "thread.next" },
        { key: "mod+alt+[", command: "thread.next" },
      ]);

      yield* Effect.gen(function* () {
        const keybindings = yield* Keybindings.Keybindings;
        yield* keybindings.syncDefaultKeybindingsOnStartup;
      });

      const persisted = yield* readKeybindingsConfig(keybindingsConfigPath);
      const hasRule = (key: string, command: KeybindingCommand) =>
        persisted.some((entry) => entry.key === key && entry.command === command);
      assert.isFalse(hasRule("mod+[", "thread.previous"));
      assert.isFalse(hasRule("mod+]", "thread.next"));
      assert.isTrue(hasRule("mod+shift+[", "thread.previous"));
      assert.isTrue(hasRule("mod+alt+[", "thread.next"));
      assert.isTrue(hasRule("mod+[", "navigation.back"));
      assert.isTrue(hasRule("mod+]", "navigation.forward"));
    }).pipe(Effect.provide(layerKeybindings())),
  );

  it.effect("leaves a remapped command's defaults out of the backfill", () =>
    Effect.gen(function* () {
      const { keybindingsConfigPath } = yield* ServerConfig.ServerConfig;
      yield* writeKeybindingsConfig(keybindingsConfigPath, [
        { key: "mod+alt+p", command: "thread.previous" },
      ]);

      yield* Effect.gen(function* () {
        const keybindings = yield* Keybindings.Keybindings;
        yield* keybindings.syncDefaultKeybindingsOnStartup;
      });

      const persisted = yield* readKeybindingsConfig(keybindingsConfigPath);
      const previousKeys = persisted
        .filter((entry) => entry.command === "thread.previous")
        .map((entry) => entry.key);
      assert.deepEqual(previousKeys, ["mod+alt+p"]);
    }).pipe(Effect.provide(layerKeybindings())),
  );
});
