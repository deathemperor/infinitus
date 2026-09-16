import { assert, describe, it } from "@effect/vitest";
import { ProviderInstanceId } from "@t3tools/contracts";

import { hasValidClaudeManifestAdapters } from "./ClaudeModelManifest.ts";
import type { ModelManifestData } from "./ModelManifest.ts";
import {
  formatClaudeVersionUpgradeMessage,
  normalizeClaudeCatalogEffort,
  resolveClaudeCatalogApiModelId,
  resolveClaudeCatalogContextWindowTokens,
  resolveClaudeCatalogEffort,
  resolveClaudeModelCatalog,
  resolveClaudeModelsForVersion,
  resolveClaudeModelSlug,
  scopeClaudeModelCatalog,
} from "./ClaudeModelCatalog.ts";

/**
 * Test policy: adding or changing a real Claude model in model-manifest.json
 * must not add or update tests here. These synthetic fixtures cover resolver
 * behavior once. Add a test only when Claude adapter semantics change, such
 * as introducing a new compatibility rule or dispatch mapping type.
 */

const manifest = (): ModelManifestData => ({
  version: 1,
  currentModels: {},
  providers: {
    claudeAgent: {
      profiles: {
        synthetic: {
          capabilities: {
            optionDescriptors: [
              {
                id: "effort",
                label: "Reasoning",
                type: "select",
                options: [{ id: "extreme", label: "Extreme", isDefault: true }],
              },
              {
                id: "contextWindow",
                label: "Context Window",
                type: "select",
                options: [{ id: "large", label: "Large", isDefault: true }],
              },
            ],
          },
          adapter: {
            claudeCode: {
              effortMap: { extreme: "high" },
              modelSuffixes: { contextWindow: { large: "[large]" } },
            },
          },
        },
      },
      models: [
        {
          slug: "claude-synthetic-next",
          name: "Claude Synthetic Next",
          aliases: ["synthetic"],
          status: "current",
          profile: "synthetic",
          adapter: { claudeCode: { minVersion: "3.2.0" } },
        },
      ],
    },
  },
});

describe("Claude model catalog", () => {
  it("filters models at runtime-version boundaries and derives the upgrade message", () => {
    const catalog = resolveClaudeModelCatalog(manifest());
    assert.deepStrictEqual(resolveClaudeModelsForVersion(catalog, "3.1.9"), []);
    assert.deepStrictEqual(
      resolveClaudeModelsForVersion(catalog, "3.2.0").map((model) => model.slug),
      ["claude-synthetic-next"],
    );
    assert.strictEqual(
      formatClaudeVersionUpgradeMessage(catalog, "3.1.9"),
      "Claude Code v3.1.9 is too old for Claude Synthetic Next. Upgrade to v3.2.0 or newer to access it.",
    );
  });

  it("resolves aliases and declarative adapter mappings", () => {
    const base = manifest();
    const input: ModelManifestData = {
      ...base,
      providers: {
        ...base.providers,
        claudeAgent: {
          ...base.providers!.claudeAgent!,
          models: [
            {
              slug: "claude-synthetic-collision",
              name: "Claude Synthetic Collision",
              aliases: ["claude-synthetic-next"],
              status: "current",
            },
            ...base.providers!.claudeAgent!.models,
          ],
        },
      },
    };
    const catalog = resolveClaudeModelCatalog(input);
    assert.strictEqual(resolveClaudeModelSlug(catalog, "synthetic"), "claude-synthetic-next");
    assert.strictEqual(
      resolveClaudeModelSlug(catalog, "claude-synthetic-next"),
      "claude-synthetic-next",
    );
    assert.strictEqual(normalizeClaudeCatalogEffort(catalog, "extreme", "synthetic"), "high");
    assert.strictEqual(
      resolveClaudeCatalogApiModelId(catalog, {
        instanceId: ProviderInstanceId.make("claudeAgent"),
        model: "synthetic",
      }),
      "claude-synthetic-next[large]",
    );
    // A proxied instance (#1088) takes the plain slug: the bracket suffix is
    // Anthropic's own syntax and an Anthropic-compatible proxy rejects it.
    assert.strictEqual(
      resolveClaudeCatalogApiModelId(
        catalog,
        { instanceId: ProviderInstanceId.make("claudeAgent"), model: "synthetic" },
        { modelSuffixes: false },
      ),
      "claude-synthetic-next",
    );
  });

  it("rejects malformed adapter mappings", () => {
    const base = manifest();
    const malformed: ModelManifestData = {
      ...base,
      providers: {
        ...base.providers,
        claudeAgent: {
          ...base.providers!.claudeAgent!,
          profiles: {
            ...base.providers!.claudeAgent!.profiles,
            synthetic: {
              ...base.providers!.claudeAgent!.profiles.synthetic!,
              adapter: { claudeCode: { effortMap: { extreme: 123 } } },
            },
          },
        },
      },
    };
    assert.isFalse(hasValidClaudeManifestAdapters(malformed));
  });

  it("appends custom models with their own descriptors and keeps bare slugs opaque", () => {
    const catalog = scopeClaudeModelCatalog(resolveClaudeModelCatalog(manifest()), [
      "synthetic",
      {
        slug: "claude-custom-tuned",
        name: "Tuned",
        capabilities: {
          optionDescriptors: [
            {
              id: "effort",
              label: "Reasoning",
              type: "select",
              options: [
                { id: "gentle", label: "Gentle", isDefault: true },
                { id: "brutal", label: "Brutal" },
              ],
            },
          ],
        },
      },
    ]);

    // The bare custom slug shadows the built-in alias, so it no longer resolves to it.
    assert.strictEqual(resolveClaudeModelSlug(catalog, "synthetic"), "synthetic");
    assert.strictEqual(resolveClaudeCatalogEffort(catalog, "synthetic", "extreme"), undefined);

    // The entry with descriptors resolves user-defined effort ids and passes
    // them through untouched (no effortMap, no model suffix).
    assert.strictEqual(
      resolveClaudeCatalogEffort(catalog, "claude-custom-tuned", "brutal"),
      "brutal",
    );
    assert.strictEqual(
      resolveClaudeCatalogEffort(catalog, "claude-custom-tuned", "bogus"),
      "gentle",
    );
    assert.strictEqual(
      normalizeClaudeCatalogEffort(catalog, "brutal", "claude-custom-tuned"),
      "brutal",
    );
    assert.strictEqual(
      resolveClaudeCatalogApiModelId(catalog, {
        instanceId: ProviderInstanceId.make("claudeAgent"),
        model: "claude-custom-tuned",
        options: [{ id: "effort", value: "brutal" }],
      }),
      "claude-custom-tuned",
    );
    assert.deepStrictEqual(
      resolveClaudeModelsForVersion(catalog, "3.2.0").map((model) => model.slug),
      ["claude-synthetic-next", "claude-custom-tuned"],
    );
  });

  it("maps a custom entry's context window choices to tokens and the wire suffix", () => {
    const catalog = scopeClaudeModelCatalog(resolveClaudeModelCatalog(manifest()), [
      {
        slug: "proxy/claude-opus-5",
        name: "Proxied",
        capabilities: {
          optionDescriptors: [
            {
              id: "contextWindow",
              label: "Context Window",
              type: "select",
              options: [
                { id: "200k", label: "200k", isDefault: true },
                { id: "1m", label: "1M" },
                { id: "roomy", label: "Roomy" },
              ],
            },
          ],
        },
      },
    ]);
    const select = (value: string) => ({
      instanceId: ProviderInstanceId.make("claudeAgent"),
      model: "proxy/claude-opus-5",
      options: [{ id: "contextWindow", value }],
    });

    // The window the adapter reads to decide whether to send the long-context
    // beta, which is a proxied instance's only route to 1M.
    assert.strictEqual(resolveClaudeCatalogContextWindowTokens(catalog, select("200k")), 200_000);
    assert.strictEqual(resolveClaudeCatalogContextWindowTokens(catalog, select("1m")), 1_000_000);
    // An id the manifest does not use resolves no window at all, so it buys
    // neither the beta nor the suffix.
    assert.strictEqual(
      resolveClaudeCatalogContextWindowTokens(catalog, select("roomy")),
      undefined,
    );
    assert.strictEqual(
      resolveClaudeCatalogApiModelId(catalog, select("roomy")),
      "proxy/claude-opus-5",
    );

    // A direct instance takes Anthropic's own syntax; a proxied one the plain
    // slug, since the suffix is what it answers 400 to (#1088).
    assert.strictEqual(
      resolveClaudeCatalogApiModelId(catalog, select("1m")),
      "proxy/claude-opus-5[1m]",
    );
    assert.strictEqual(
      resolveClaudeCatalogApiModelId(catalog, select("200k")),
      "proxy/claude-opus-5",
    );
    assert.strictEqual(
      resolveClaudeCatalogApiModelId(catalog, select("1m"), { modelSuffixes: false }),
      "proxy/claude-opus-5",
    );
  });

  it("leaves a custom entry without context choices unmapped", () => {
    const catalog = scopeClaudeModelCatalog(resolveClaudeModelCatalog(manifest()), [
      {
        slug: "claude-custom-plain",
        name: "Plain",
        capabilities: {
          optionDescriptors: [{ id: "fastMode", label: "Fast Mode", type: "boolean" }],
        },
      },
    ]);
    assert.strictEqual(
      resolveClaudeCatalogContextWindowTokens(catalog, {
        instanceId: ProviderInstanceId.make("claudeAgent"),
        model: "claude-custom-plain",
      }),
      undefined,
    );
  });
});
