import type { SDKModel } from "@cursor/sdk";
import { describe, expect, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as Schema from "effect/Schema";
import type { CursorSettings } from "@infinitus/contracts";
import { CursorSettings as CursorSettingsSchema } from "@infinitus/contracts";
import { createModelCapabilities } from "@infinitus/shared/model";
import { PRODUCT_NAME } from "@infinitus/shared/productName";

import {
  buildCursorCapabilitiesFromSdkModel,
  buildCursorDiscoveredModelsFromSdk,
  buildCursorProviderSnapshot,
  buildInitialCursorProviderSnapshot,
  checkCursorProviderStatus,
} from "./CursorProvider.ts";
import * as CursorSdkCatalog from "./CursorSdkCatalog.ts";

const decodeCursorSettings = Schema.decodeSync(CursorSettingsSchema);

function selectDescriptor(
  id: string,
  label: string,
  options: ReadonlyArray<{ id: string; label: string; isDefault?: boolean }>,
) {
  return {
    id,
    label,
    type: "select" as const,
    options: [...options],
    ...(options.find((option) => option.isDefault)?.id
      ? { currentValue: options.find((option) => option.isDefault)?.id }
      : {}),
  };
}

function booleanDescriptor(id: string, label: string, currentValue?: boolean) {
  return {
    id,
    label,
    type: "boolean" as const,
    ...(typeof currentValue === "boolean" ? { currentValue } : {}),
  };
}

const baseCursorSettings: CursorSettings = decodeCursorSettings({
  enabled: true,
  customModels: [],
<<<<<<< HEAD
};
const cursorAcpDiscoveryFailedMessage = [
  "Cursor ACP model discovery failed.",
  `Cursor CLI setup may be incomplete; install or enable the Cursor CLI, restart ${PRODUCT_NAME}, and try again.`,
  "See https://cursor.com/docs/cli/installation.",
  "Check server logs for ACP details.",
].join(" ");
const missingCursorBinaryPath = "/definitely/not/installed/t3-cursor-agent";
const cursorCliCommandMissingMessage = [
  `Cursor CLI command \`${missingCursorBinaryPath}\` was not found.`,
  `Install or enable the Cursor CLI, make sure \`${missingCursorBinaryPath}\` is on PATH, then restart ${PRODUCT_NAME}.`,
  "See https://cursor.com/docs/cli/installation.",
].join(" ");

describe("Cursor skills", () => {
  it("discovers recursive project skills with project precedence", async () =>
    await runNode(
      Effect.gen(function* () {
        const fileSystem = yield* FileSystem.FileSystem;
        const path = yield* Path.Path;
        const userHome = yield* fileSystem.makeTempDirectory({
          directory: NodeOS.tmpdir(),
          prefix: "cursor-skills-home-",
        });
        const workspace = yield* fileSystem.makeTempDirectory({
          directory: NodeOS.tmpdir(),
          prefix: "cursor-skills-workspace-",
        });
        const writeSkill = Effect.fn("writeCursorSkill")(function* (
          root: string,
          name: string,
          contents: string,
        ) {
          const skillDirectory = path.join(root, name);
          yield* fileSystem.makeDirectory(skillDirectory, { recursive: true });
          yield* fileSystem.writeFileString(path.join(skillDirectory, "SKILL.md"), contents);
        });

        yield* writeSkill(
          path.join(userHome, ".cursor", "skills"),
          "review",
          "---\ndescription: user review\n---\n",
        );
        yield* writeSkill(
          path.join(workspace, ".agents", "skills", "nested"),
          "review",
          "---\nname: Review changes\ndescription: project review\n---\n",
        );
        yield* writeSkill(
          path.join(workspace, ".cursor", "skills"),
          "internal",
          "---\nuser-invocable: false\n---\n",
        );
        yield* writeSkill(
          path.join(workspace, ".cursor", "skills"),
          "oversized",
          "x".repeat(1_000_001),
        );
        yield* fileSystem.makeDirectory(path.join(userHome, ".codex"), { recursive: true });
        yield* fileSystem.writeFileString(
          path.join(userHome, ".codex", "skills"),
          "not a directory",
        );

        const skills = yield* discoverCursorSkills(workspace, { HOME: userHome });
        expect(skills).toEqual([
          {
            name: "internal",
            path: path.join(workspace, ".cursor", "skills", "internal", "SKILL.md"),
            scope: "project",
            enabled: true,
            userInvocable: false,
          },
          {
            name: "oversized",
            path: path.join(workspace, ".cursor", "skills", "oversized", "SKILL.md"),
            scope: "project",
            enabled: true,
          },
          {
            name: "review",
            displayName: "Review changes",
            description: "project review",
            path: path.join(workspace, ".agents", "skills", "nested", "review", "SKILL.md"),
            scope: "project",
            enabled: true,
          },
        ]);
        expect(
          (yield* probeCursorSkills(workspace, { HOME: userHome }).pipe(Effect.result))._tag,
        ).toBe("Failure");
      }),
    ));

  it("treats a symlinked skill outside the root as a package boundary", async () =>
    await runNode(
      Effect.gen(function* () {
        const fileSystem = yield* FileSystem.FileSystem;
        const path = yield* Path.Path;
        const userHome = yield* fileSystem.makeTempDirectory({
          directory: NodeOS.tmpdir(),
          prefix: "cursor-skills-home-",
        });
        const workspace = yield* fileSystem.makeTempDirectory({
          directory: NodeOS.tmpdir(),
          prefix: "cursor-skills-workspace-",
        });
        const library = yield* fileSystem.makeTempDirectory({
          directory: NodeOS.tmpdir(),
          prefix: "cursor-skills-library-",
        });
        const writeSkill = Effect.fn("writeCursorSkill")(function* (
          directory: string,
          contents: string,
        ) {
          yield* fileSystem.makeDirectory(directory, { recursive: true });
          yield* fileSystem.writeFileString(path.join(directory, "SKILL.md"), contents);
        });

        // A skill package managed in a config repo and installed by symlink.
        // Its own SKILL.md must be discovered under the link name, but nothing
        // below the target may be walked.
        yield* writeSkill(path.join(library, "shared-review"), "---\ndescription: shared\n---\n");
        yield* writeSkill(path.join(library, "shared-review", "hidden"), "---\n---\n");
        const root = path.join(workspace, ".cursor", "skills");
        yield* fileSystem.makeDirectory(root, { recursive: true });
        yield* fileSystem.symlink(path.join(library, "shared-review"), path.join(root, "review"));

        const skills = yield* discoverCursorSkills(workspace, { HOME: userHome });
        expect(skills).toEqual([
          {
            name: "review",
            description: "shared",
            path: path.join(root, "review", "SKILL.md"),
            scope: "project",
            enabled: true,
          },
        ]);
        expect(
          (yield* probeCursorSkills(workspace, { HOME: userHome }).pipe(Effect.result))._tag,
        ).toBe("Success");
      }),
    ));

  it("rewrites only discovered skill mentions into Cursor slash invocations", () => {
    expect(hasCursorSkillMention("use $Review_Pr:V2 here")).toBe(true);
    expect(hasCursorSkillMention("please $review this")).toBe(true);
    expect(
      rewriteCursorSkillMentions("use $review, keep $HOME and 5$review", new Set(["review"])),
    ).toBe("use $review, keep $HOME and 5$review");
    expect(rewriteCursorSkillMentions("please $review this", new Set(["review"]))).toBe(
      "please /review this",
    );
  });

  it("rewrites currency-prefixed skill mentions into Cursor slash invocations", () => {
    const names = new Set(["review", "2spec", "20k", "100M", "1e6"]);
    for (const symbol of ["€", "£", "¥", "₹", "₩", "₿", "𑿝"]) {
      expect(hasCursorSkillMention(`please ${symbol}review this`)).toBe(true);
      expect(hasCursorSkillMention(`please ${symbol}review this`)).toBe(true);
      expect(rewriteCursorSkillMentions(`${symbol}review then ${symbol}2spec this`, names)).toBe(
        "/review then /2spec this",
      );
      const money = `${symbol}20 ${symbol}20k ${symbol}100M ${symbol}1e6`;
      expect(hasCursorSkillMention(money)).toBe(false);
      expect(rewriteCursorSkillMentions(money, names)).toBe(money);
      const prose = `5${symbol}review ${symbol}unknown`;
      expect(rewriteCursorSkillMentions(prose, names)).toBe(prose);
    }
  });

  it("detects and invokes digit-leading Cursor skills without rewriting money", () => {
    const names = new Set(["2spec", "20k", "100M", "1e6"]);
    // Repeated presence checks must not carry a global-regex cursor.
    expect(hasCursorSkillMention("use $2spec here")).toBe(true);
    expect(hasCursorSkillMention("use $2spec here")).toBe(true);
    expect(rewriteCursorSkillMentions("use $2spec here", names)).toBe("use /2spec here");
    expect(rewriteCursorSkillMentions("use $2spec here", new Set())).toBe("use $2spec here");
    for (const text of [
      "pay $20 tomorrow",
      "budget $20k here",
      "cost $100M total",
      "limit $1e6 here",
    ]) {
      expect(hasCursorSkillMention(text)).toBe(false);
      expect(rewriteCursorSkillMentions(text, names)).toBe(text);
    }
  });
=======
>>>>>>> upstream-sync-0fe4fa40f-upstream-renamed
});

const sdkParameterizedModel = {
  id: "claude-opus-4-8",
  displayName: "Opus 4.8",
  parameters: [
    {
      id: "thinking",
      displayName: "Thinking",
      values: [{ value: "false" }, { value: "true" }],
    },
    {
      id: "context",
      displayName: "Context",
      values: [
        { value: "300k", displayName: "300K" },
        { value: "1m", displayName: "1M" },
      ],
    },
    {
      id: "effort",
      displayName: "Effort",
      values: [
        { value: "low", displayName: "Low" },
        { value: "high", displayName: "High" },
      ],
    },
    {
      id: "fast",
      displayName: "Fast",
      values: [{ value: "false" }, { value: "true", displayName: "Fast" }],
    },
  ],
  variants: [
    {
      displayName: "Opus 4.8",
      isDefault: true,
      params: [
        { id: "thinking", value: "true" },
        { id: "context", value: "1m" },
        { id: "effort", value: "high" },
        { id: "fast", value: "false" },
      ],
    },
  ],
} satisfies SDKModel;

describe("buildInitialCursorProviderSnapshot", () => {
  it.effect("uses SDK-specific pending status copy", () =>
    Effect.gen(function* () {
      const provider = yield* buildInitialCursorProviderSnapshot(baseCursorSettings);

      expect(provider).toMatchObject({
        status: "warning",
        message: "Checking Cursor SDK availability...",
      });
    }),
  );
});

describe("buildCursorProviderSnapshot", () => {
  it("downgrades ready status to warning when SDK model discovery returns no models", () => {
    expect(
      buildCursorProviderSnapshot({
        checkedAt: "2026-01-01T00:00:00.000Z",
        cursorSettings: baseCursorSettings,
        parsed: {
          version: null,
          status: "ready",
          auth: { status: "authenticated", type: "api-key", label: "Cursor API key" },
        },
        discoveryWarning: "Cursor SDK model discovery returned no built-in models.",
      }),
    ).toMatchObject({
      status: "warning",
      message: "Cursor SDK model discovery returned no built-in models.",
      models: [],
      supportsConversationRollback: false,
    });
  });
});

describe("Cursor SDK model discovery", () => {
  it("maps native SDK parameter ids and default variant values to model capabilities", () => {
    expect(buildCursorCapabilitiesFromSdkModel(sdkParameterizedModel)).toEqual(
      createModelCapabilities({
        optionDescriptors: [
          selectDescriptor("effort", "Effort", [
            { id: "low", label: "Low" },
            { id: "high", label: "High", isDefault: true },
          ]),
          selectDescriptor("contextWindow", "Context", [
            { id: "300k", label: "300K" },
            { id: "1m", label: "1M", isDefault: true },
          ]),
          booleanDescriptor("fastMode", "Fast", false),
          booleanDescriptor("thinking", "Thinking", true),
        ],
      }),
    );
  });

  it("filters invalid and duplicate SDK model entries", () => {
    expect(
      buildCursorDiscoveredModelsFromSdk([
        sdkParameterizedModel,
        { ...sdkParameterizedModel, displayName: "Duplicate" },
        { id: "", displayName: "Invalid" },
      ]),
    ).toEqual([
      {
        slug: "claude-opus-4-8",
        name: "Opus 4.8",
        isCustom: false,
        capabilities: buildCursorCapabilitiesFromSdkModel(sdkParameterizedModel),
      },
    ]);
  });
});

describe("checkCursorProviderStatus", () => {
  it.effect("uses the SDK catalog when CURSOR_API_KEY is configured", () =>
    Effect.gen(function* () {
      const provider = yield* checkCursorProviderStatus(
        {
          ...baseCursorSettings,
          customModels: ["internal/cursor-model"],
        },
        { CURSOR_API_KEY: "test-cursor-key" },
      ).pipe(
        Effect.provide(
          CursorSdkCatalog.makeCursorSdkCatalogTestLayer((apiKey) => {
            expect(apiKey).toBe("test-cursor-key");
            return Effect.succeed({
              user: {
                apiKeyName: "test-key",
                userEmail: "cursor@example.com",
                createdAt: "2026-01-01T00:00:00.000Z",
              },
              models: [sdkParameterizedModel],
            });
          }),
        ),
      );

      expect(provider).toMatchObject({
        status: "ready",
        auth: {
          status: "authenticated",
          type: "api-key",
          label: "Cursor API key (test-key)",
          email: "cursor@example.com",
        },
        models: [
          { slug: "claude-opus-4-8", isCustom: false },
          { slug: "internal/cursor-model", isCustom: true },
        ],
      });
    }),
  );

  it.effect("surfaces SDK authentication failures", () =>
    Effect.gen(function* () {
      const provider = yield* checkCursorProviderStatus(baseCursorSettings, {
        CURSOR_API_KEY: "invalid-test-key",
      }).pipe(
        Effect.provide(
          CursorSdkCatalog.makeCursorSdkCatalogTestLayer(() =>
            Effect.fail(
              new CursorSdkCatalog.CursorSdkCatalogError({
                authenticationFailure: true,
                cause: new Error("unauthorized"),
              }),
            ),
          ),
        ),
      );

      expect(provider).toMatchObject({
        status: "error",
        auth: { status: "unauthenticated" },
        message: "Cursor SDK authentication failed. Check CURSOR_API_KEY.",
      });
    }),
  );

  it.effect("requires a Cursor API key without probing any external Cursor binary", () =>
    Effect.gen(function* () {
      const provider = yield* checkCursorProviderStatus(baseCursorSettings).pipe(
        Effect.provide(
          CursorSdkCatalog.makeCursorSdkCatalogTestLayer(() =>
            Effect.die("SDK catalog must not be used without CURSOR_API_KEY"),
          ),
        ),
      );

      expect(provider).toMatchObject({
        installed: true,
        status: "error",
        auth: { status: "unauthenticated" },
        message: "Sign in with Cursor or add CURSOR_API_KEY in provider settings.",
      });
    }),
  );
});
