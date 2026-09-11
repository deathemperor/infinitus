import { describe, expect, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import { HttpClient, HttpClientResponse } from "effect/unstable/http";

import { fetchProxyModels } from "./proxyModels.ts";

type Seen = { url: string; headers: Record<string, string> };

/** `fetchProxyModels` against a stub proxy; `seen` records what it was asked. */
const attempt = (
  input: { baseUrl: string; apiKey: string },
  answer: (request: Seen) => Response,
  seen: Seen[] = [],
) =>
  fetchProxyModels(input).pipe(
    Effect.provideService(
      HttpClient.HttpClient,
      HttpClient.make((request) =>
        Effect.sync(() => {
          const record = { url: request.url, headers: request.headers as Record<string, string> };
          seen.push(record);
          return HttpClientResponse.fromWeb(request, answer(record));
        }),
      ),
    ),
    Effect.result,
  );

describe("fetchProxyModels", () => {
  it.effect("lists the ids at <baseUrl>/models with the key as a bearer", () =>
    Effect.gen(function* () {
      const seen: Seen[] = [];
      const result = yield* attempt(
        { baseUrl: "http://127.0.0.1:20128/v1/", apiKey: "sk-test" },
        () => Response.json({ data: [{ id: "kr/auto" }, { id: "kr/claude-opus-5" }] }),
        seen,
      );
      expect(result._tag === "Success" && result.success).toEqual({
        models: ["kr/auto", "kr/claude-opus-5"],
      });
      expect(seen[0]?.url).toBe("http://127.0.0.1:20128/v1/models");
      expect(seen[0]?.headers.authorization).toBe("Bearer sk-test");
      expect(seen[0]?.headers["x-api-key"]).toBe("sk-test");
    }),
  );

  it.effect("reports the status without the key when the proxy refuses", () =>
    Effect.gen(function* () {
      const result = yield* attempt(
        { baseUrl: "http://127.0.0.1:20128/v1", apiKey: "sk-secret" },
        () => Response.json({ error: "nope" }, { status: 401 }),
      );
      expect(result._tag).toBe("Failure");
      if (result._tag === "Failure") {
        expect(result.failure.detail).toBe("The proxy answered 401.");
        expect(String(result.failure)).not.toContain("sk-secret");
      }
    }),
  );

  it.effect("rejects a malformed list", () =>
    Effect.gen(function* () {
      const result = yield* attempt({ baseUrl: "http://127.0.0.1:20128/v1", apiKey: "k" }, () =>
        Response.json({ models: ["a"] }),
      );
      expect(result._tag === "Failure" && result.failure.detail).toBe(
        "The proxy's model list has an unexpected shape.",
      );
    }),
  );

  it.effect("rejects an unparsable base URL before any request", () =>
    Effect.gen(function* () {
      const seen: Seen[] = [];
      const result = yield* attempt(
        { baseUrl: "not a url", apiKey: "k" },
        () => Response.json({ data: [] }),
        seen,
      );
      expect(result._tag === "Failure" && result.failure.detail).toBe("The base URL is not valid.");
      expect(seen).toHaveLength(0);
    }),
  );
});
