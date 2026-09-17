import { describe, expect, it } from "vite-plus/test";

import { parsePiModelsCliOutput } from "./piModels.logic.ts";

const TABLE = [
  "provider   model                       context  max-out  thinking  images",
  "anthropic  claude-opus-5               1M       128K     yes       yes",
  "anthropic  claude-haiku-4-5            200K     64K      yes       yes",
  "zai        glm-5.3                     200K     64K      yes       no",
].join("\n");

describe("parsePiModelsCliOutput", () => {
  it("reads provider/model pairs out of the fixed-width table", () => {
    const parsed = parsePiModelsCliOutput(TABLE);
    expect(parsed.authenticated).toBe(true);
    expect(parsed.models.map((model) => model.slug)).toEqual([
      "anthropic/claude-opus-5",
      "anthropic/claude-haiku-4-5",
      "zai/glm-5.3",
    ]);
  });

  it("drops the header rather than reading it as a model", () => {
    const parsed = parsePiModelsCliOutput(TABLE);
    expect(parsed.models.some((model) => model.slug.startsWith("provider/"))).toBe(false);
  });

  it("treats an empty table as unauthenticated instead of failing", () => {
    expect(parsePiModelsCliOutput("")).toEqual({ authenticated: false, models: [] });
    expect(parsePiModelsCliOutput("provider   model   context")).toEqual({
      authenticated: false,
      models: [],
    });
  });

  it("reads Pi's signed-out message as unauthenticated, not as a model", () => {
    expect(
      parsePiModelsCliOutput(
        "No models available. Use /login to log into a provider via OAuth or API key.",
      ),
    ).toEqual({ authenticated: false, models: [] });
  });

  it("drops a short or malformed row without losing the rest", () => {
    const parsed = parsePiModelsCliOutput(
      ["provider  model", "anthropic  claude-opus-5  1M", "garbage", "zai  glm-5.3  200K"].join(
        "\n",
      ),
    );
    expect(parsed.models.map((model) => model.slug)).toEqual([
      "anthropic/claude-opus-5",
      "zai/glm-5.3",
    ]);
  });

  it("does not list the same model twice", () => {
    const parsed = parsePiModelsCliOutput(
      ["provider  model", "zai  glm-5.3  200K", "zai  glm-5.3  200K"].join("\n"),
    );
    expect(parsed.models).toHaveLength(1);
  });
});
