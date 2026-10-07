// @effect-diagnostics nodeBuiltinImport:off - joins paths inside a temp dir.
import * as NodePath from "node:path";

import * as NodeServices from "@effect/platform-node/NodeServices";
import { describe, expect, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Schema from "effect/Schema";

import { mergePiProxyModelsJson, piProxyProvider, writePiProxyModelsFile } from "./piProxyHome.ts";

const parseJson = Schema.decodeUnknownSync(Schema.fromJsonString(Schema.Unknown));
const provider = piProxyProvider({ PI_PROXY_BASE_URL: "http://h:1" }, ["proxy/kr/x"])!;

describe("piProxyProvider", () => {
  it("is nothing for an instance without a proxy base URL", () => {
    expect(piProxyProvider({}, ["proxy/kr/x"])).toBeUndefined();
    expect(piProxyProvider({ PI_PROXY_BASE_URL: "  " }, ["proxy/kr/x"])).toBeUndefined();
  });

  it("is an openai-completions provider whose key is read from the env", () => {
    expect(
      piProxyProvider({ PI_PROXY_BASE_URL: "http://127.0.0.1:20128/" }, [
        "proxy/kr/gpt-5.6-sol",
        { slug: "proxy/cc/claude-opus-5" },
        "anthropic/claude-opus-5",
      ]),
    ).toEqual({
      baseUrl: "http://127.0.0.1:20128/v1",
      api: "openai-completions",
      // Pi interpolates `$VAR` at request time, so the key never lands on disk.
      apiKey: "$PI_PROXY_API_KEY",
      models: [{ id: "kr/gpt-5.6-sol" }, { id: "cc/claude-opus-5" }],
    });
  });

  it("keeps a base URL that already ends in /v1", () => {
    expect(piProxyProvider({ PI_PROXY_BASE_URL: "http://h:1/v1" }, [])?.baseUrl).toBe(
      "http://h:1/v1",
    );
  });
});

describe("mergePiProxyModelsJson", () => {
  it("keeps the providers a typed home already declares", () => {
    const existing = '{"providers":{"ollama":{"baseUrl":"http://o/v1"},"proxy":{"old":1}},"x":1}';
    expect(parseJson(mergePiProxyModelsJson(existing, provider)!)).toEqual({
      x: 1,
      providers: { ollama: { baseUrl: "http://o/v1" }, proxy: provider },
    });
  });

  it("never replaces a file it cannot read as a JSON object", () => {
    expect(mergePiProxyModelsJson("// hand notes {", provider)).toBeUndefined();
    expect(mergePiProxyModelsJson("[]", provider)).toBeUndefined();
    expect(mergePiProxyModelsJson('{"providers":"x"}', provider)).toBeUndefined();
  });
});

it.layer(NodeServices.layer)("writePiProxyModelsFile", (it) => {
  it.effect("writes models.json into the instance home, creating it", () =>
    Effect.gen(function* () {
      const fileSystem = yield* FileSystem.FileSystem;
      const directory = yield* fileSystem.makeTempDirectoryScoped({ prefix: "pi-proxy-home-" });
      const homePath = NodePath.join(directory, "nested", "home");
      const written = yield* writePiProxyModelsFile(
        { homePath, customModels: ["proxy/kr/x"] },
        { PI_PROXY_BASE_URL: "http://h:1" },
      );
      expect(written).toBe(NodePath.join(homePath, "models.json"));
      expect(parseJson(yield* fileSystem.readFileString(written!))).toEqual({
        providers: { proxy: provider },
      });
    }),
  );

  it.effect("leaves the home alone when the instance has no proxy", () =>
    Effect.gen(function* () {
      const fileSystem = yield* FileSystem.FileSystem;
      const directory = yield* fileSystem.makeTempDirectoryScoped({ prefix: "pi-proxy-home-" });
      const homePath = NodePath.join(directory, "home");
      yield* writePiProxyModelsFile({ homePath, customModels: ["proxy/kr/x"] }, {});
      expect(yield* fileSystem.exists(homePath)).toBe(false);
    }),
  );

  it.effect("never writes into Pi's default home", () =>
    Effect.gen(function* () {
      // An empty homePath means ~/.pi/agent, the user's own config directory.
      const written = yield* writePiProxyModelsFile(
        { homePath: "", customModels: [] },
        { PI_PROXY_BASE_URL: "http://h:1" },
      );
      expect(written).toBeUndefined();
    }),
  );
});
