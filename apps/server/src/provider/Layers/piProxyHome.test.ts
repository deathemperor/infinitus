// @effect-diagnostics nodeBuiltinImport:off - joins paths inside a temp dir.
import * as NodePath from "node:path";

import * as NodeServices from "@effect/platform-node/NodeServices";
import { describe, expect, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Schema from "effect/Schema";

const parseJson = Schema.decodeUnknownSync(Schema.fromJsonString(Schema.Unknown));

import { piProxyModelsJson, writePiProxyModelsFile } from "./piProxyHome.ts";

describe("piProxyModelsJson", () => {
  it("is nothing for an instance without a proxy base URL", () => {
    expect(piProxyModelsJson({}, ["proxy/kr/x"])).toBeUndefined();
    expect(piProxyModelsJson({ PI_PROXY_BASE_URL: "  " }, ["proxy/kr/x"])).toBeUndefined();
  });

  it("declares one openai-completions provider whose key is read from the env", () => {
    const json = piProxyModelsJson({ PI_PROXY_BASE_URL: "http://127.0.0.1:20128/" }, [
      "proxy/kr/gpt-5.6-sol",
      { slug: "proxy/cc/claude-opus-5" },
      "anthropic/claude-opus-5",
    ]);
    expect((parseJson(json!) as any)).toEqual({
      providers: {
        proxy: {
          baseUrl: "http://127.0.0.1:20128/v1",
          api: "openai-completions",
          // Pi interpolates `$VAR` at request time, so the key never lands on disk.
          apiKey: "$PI_PROXY_API_KEY",
          models: [{ id: "kr/gpt-5.6-sol" }, { id: "cc/claude-opus-5" }],
        },
      },
    });
  });

  it("keeps a base URL that already ends in /v1", () => {
    const json = piProxyModelsJson({ PI_PROXY_BASE_URL: "http://h:1/v1" }, []);
    expect((parseJson(json!) as any).providers.proxy.baseUrl).toBe("http://h:1/v1");
  });
});

it.layer(NodeServices.layer)("writePiProxyModelsFile", (it) => {
  it.effect("writes models.json into the instance home, creating it", () =>
    Effect.gen(function* () {
      const fileSystem = yield* FileSystem.FileSystem;
      const directory = yield* fileSystem.makeTempDirectoryScoped({ prefix: "pi-proxy-home-" });
      const homePath = NodePath.join(directory, "nested", "home");
      yield* writePiProxyModelsFile(
        { homePath, customModels: ["proxy/kr/x"] },
        { PI_PROXY_BASE_URL: "http://h:1" },
      );
      const written = parseJson(
        yield* fileSystem.readFileString(NodePath.join(homePath, "models.json")),
      ) as any;
      expect(written.providers.proxy.models).toEqual([{ id: "kr/x" }]);
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
      // An empty homePath means ~/.pi/agent, the user's real config: a proxy
      // instance without its own dir must not overwrite their models.json.
      yield* writePiProxyModelsFile(
        { homePath: "", customModels: [] },
        { PI_PROXY_BASE_URL: "http://h:1" },
      );
    }),
  );
});
