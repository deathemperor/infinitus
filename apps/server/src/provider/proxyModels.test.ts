import * as Effect from "effect/Effect";
import { HttpClient, HttpClientResponse } from "effect/unstable/http";
import { describe, expect, it } from "vitest";

import { fetchProxyModels } from "./proxyModels.ts";

const run = (
  input: { baseUrl: string; apiKey: string },
  answer: (request: { url: string; headers: Record<string, string> }) => Response,
) =>
  Effect.runPromise(
    fetchProxyModels(input).pipe(
      Effect.provideService(
        HttpClient.HttpClient,
        HttpClient.make((request) =>
          Effect.sync(() =>
            HttpClientResponse.fromWeb(
              request,
              answer({ url: request.url, headers: request.headers as Record<string, string> }),
            ),
          ),
        ),
      ),
      Effect.match({
        onFailure: (left) => ({ _tag: "Left" as const, left }),
        onSuccess: (right) => ({ _tag: "Right" as const, right }),
      }),
    ),
  );

describe("fetchProxyModels", () => {
  it("lists the ids at <baseUrl>/models with the key as a bearer", async () => {
    const seen: Array<{ url: string; headers: Record<string, string> }> = [];
    const result = await run(
      { baseUrl: "http://127.0.0.1:20128/v1/", apiKey: "sk-test" },
      (request) => {
        seen.push(request);
        return Response.json({ data: [{ id: "kr/auto" }, { id: "kr/claude-opus-5" }] });
      },
    );
    expect(result).toEqual({ _tag: "Right", right: { models: ["kr/auto", "kr/claude-opus-5"] } });
    expect(seen[0]?.url).toBe("http://127.0.0.1:20128/v1/models");
    expect(seen[0]?.headers.authorization).toBe("Bearer sk-test");
    expect(seen[0]?.headers["x-api-key"]).toBe("sk-test");
  });

  it("reports the status without the key when the proxy refuses", async () => {
    const result = await run({ baseUrl: "http://127.0.0.1:20128/v1", apiKey: "sk-secret" }, () =>
      Response.json({ error: "nope" }, { status: 401 }),
    );
    expect(result._tag).toBe("Left");
    if (result._tag === "Left") {
      expect(result.left.detail).toBe("The proxy answered 401.");
      expect(JSON.stringify(result.left)).not.toContain("sk-secret");
    }
  });

  it("rejects a malformed list", async () => {
    const result = await run({ baseUrl: "http://127.0.0.1:20128/v1", apiKey: "k" }, () =>
      Response.json({ models: ["a"] }),
    );
    expect(result._tag === "Left" && result.left.detail).toBe(
      "The proxy's model list has an unexpected shape.",
    );
  });

  it("rejects an unparsable base URL before any request", async () => {
    const result = await run({ baseUrl: "not a url", apiKey: "k" }, () => {
      throw new Error("must not be called");
    });
    expect(result._tag === "Left" && result.left.detail).toBe("The base URL is not valid.");
  });
});
