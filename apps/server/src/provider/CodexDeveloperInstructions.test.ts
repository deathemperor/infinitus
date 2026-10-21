import * as NodeAssert from "node:assert/strict";

import {
  T3_CODE_ORCHESTRATION_INSTRUCTIONS,
  T3_CODE_ORCHESTRATION_SECTIONS,
} from "@infinitus/provider-core/server/orchestrationInstructions";
import { describe, it } from "vite-plus/test";
import { PRODUCT_NAME } from "@infinitus/shared/productName";

import {
  buildCodexAdditionalContext,
  CODEX_ADDITIONAL_CONTEXT_VALUE_MAX_BYTES,
} from "./CodexDeveloperInstructions.ts";

describe("buildCodexAdditionalContext", () => {
  describe.each([
    { model: "gpt-5.3-codex", reasoningEffort: "high" },
    { model: "custom-model", modelName: "Custom 🦊 Model", reasoningEffort: "xhigh" },
  ])("with runtime $model", (runtime) => {
    it.each([
      undefined,
      false,
      true,
      { browser: false, device: false },
      { browser: true, device: false },
      { browser: false, device: true },
      { browser: true, device: true },
    ])("keeps every entry within Codex's per-entry cap with tools %j", (availability) => {
      const context = buildCodexAdditionalContext(runtime, availability);

      for (const [key, entry] of Object.entries(context)) {
        // Codex counts ceil(UTF-8 bytes / 4) tokens, excluding keys and wrappers.
        const bytes = Buffer.byteLength(entry.value, "utf8");
        const limit = CODEX_ADDITIONAL_CONTEXT_VALUE_MAX_BYTES;
        NodeAssert.ok(
          bytes <= limit,
          `${key}: ${bytes} UTF-8 bytes exceeds Codex's ${limit}-byte per-entry cap by ${bytes - limit} bytes; split the instructions into separate entries to avoid silent truncation`,
        );
      }
    });
  });

  it("delivers all orchestration sections in authored order when keys are sorted", () => {
    const context = buildCodexAdditionalContext({
      model: "gpt-5.3-codex",
      reasoningEffort: "high",
    });
    const sections = Object.keys(context)
      .filter((key) => key.startsWith("t3_code_orchestration_"))
      .sort()
      .map((key) => context[key]!);

    NodeAssert.deepEqual(
      sections,
      T3_CODE_ORCHESTRATION_SECTIONS.map((value) => ({ kind: "application", value })),
    );
    NodeAssert.equal(
      sections.map((entry) => entry.value).join("\n\n"),
      T3_CODE_ORCHESTRATION_INSTRUCTIONS.trim(),
    );
<<<<<<< HEAD
    NodeAssert.match(instructions, new RegExp(`running in ${PRODUCT_NAME}`));
    NodeAssert.match(instructions, /Codex harness/);
    NodeAssert.match(instructions, /as gpt-5\.3-codex with high reasoning effort/);
  });

  it("describes Markdown media support in the runtime context in both modes", () => {
    {
      const instructions = runtimeInstructions({
        model: "gpt-5.3-codex",
        reasoningEffort: "high",
      });
      NodeAssert.match(
        instructions,
        /<runtime_info>.*embed images and videos.*Markdown.*<\/runtime_info>/,
      );
    }
  });

  it("includes runtime info alongside plan mode instructions", () => {
    const instructions = runtimeInstructions({
      model: "gpt-5.3-codex",
      reasoningEffort: "medium",
    });

    NodeAssert.match(buildCodexDeveloperInstructions("plan"), /^<collaboration_mode># Plan Mode/);
    NodeAssert.match(instructions, /as gpt-5\.3-codex with medium reasoning effort/);
  });

  it("varies with the model and effort of each turn", () => {
    const first = runtimeInstructions({
      model: "gpt-5.3-codex",
      reasoningEffort: "medium",
    });
    const second = runtimeInstructions({
      model: "gpt-5.4",
      reasoningEffort: "high",
    });

    NodeAssert.notEqual(first, second);
=======
>>>>>>> upstream-sync-4f651cb10-upstream-renamed
  });
});

describe("buildCodexDeveloperInstructions", () => {
  it("flattens multiline metadata into single-line runtime info", () => {
    const instructions = runtimeInstructions({
      model: "gpt\n5.3\ncodex",
      reasoningEffort: " high\neffort ",
    });

    NodeAssert.match(instructions, /as gpt 5\.3 codex with high effort reasoning effort/);
    NodeAssert.doesNotMatch(instructions, /<runtime_info>[^<]*\n/);
  });
});

<<<<<<< HEAD
describe("T3 browser developer instructions", () => {
  const runtime = { model: "gpt-5.3-codex", reasoningEffort: "high" };

  it("prefers the product-native preview tools in both collaboration modes", () => {
    {
      const instructions = toolInstructions(runtime, true);
      NodeAssert.match(instructions, /infinitus/);
      NodeAssert.match(instructions, /preview_status/);
      NodeAssert.match(instructions, /preview_open/);
      NodeAssert.match(instructions, /Do not switch to global browser skills/);
    }
  });

  it("omits the browser block entirely when the preview tools are not attached", () => {
    for (const mode of ["default", "plan"] as const) {
      const instructions = toolInstructions(runtime, false);
      NodeAssert.doesNotMatch(instructions, /preview_status/);
      NodeAssert.doesNotMatch(instructions, /preview_open/);
      NodeAssert.doesNotMatch(instructions, /T3 Code collaborative browser/);
      // Steering away from other browser automation must go with the tools;
      // keeping it would leave the model talked out of its only option.
      NodeAssert.doesNotMatch(instructions, /Do not switch to global browser skills/);
      // The rest of the collaboration mode is untouched.
      NodeAssert.match(buildCodexDeveloperInstructions(mode), /<collaboration_mode>/);
      NodeAssert.match(buildCodexDeveloperInstructions(mode), /<\/collaboration_mode>/);
    }
  });

  it("tracks the turn's MCP configuration rather than defaulting to on", () => {
    NodeAssert.match(toolInstructions(runtime, true), /preview_open/);
    NodeAssert.doesNotMatch(toolInstructions(runtime, false), /preview_open/);
  });
});

=======
>>>>>>> upstream-sync-4f651cb10-upstream-renamed
function runtimeInstructions(runtime: Parameters<typeof buildCodexAdditionalContext>[0]) {
  return buildCodexAdditionalContext(runtime).t3_code_runtime!.value;
}
