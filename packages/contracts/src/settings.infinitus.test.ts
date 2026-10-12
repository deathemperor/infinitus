// The fork's settings-schema cases, beside upstream's `settings.test.ts`.
import { describe, expect, it } from "vite-plus/test";
import * as Schema from "effect/Schema";

import {
  ClaudeSettings,
  ClientSettingsSchema,
  ClientSettingsPatch,
  ServerSettings,
  ServerSettingsPatch,
} from "./settings.ts";

const decodeClientSettings = Schema.decodeUnknownSync(ClientSettingsSchema);
const decodeClientSettingsPatch = Schema.decodeUnknownSync(ClientSettingsPatch);
const decodeServerSettings = Schema.decodeUnknownSync(ServerSettings);
const decodeServerSettingsPatch = Schema.decodeUnknownSync(ServerSettingsPatch);
const decodeClaudeSettings = Schema.decodeUnknownSync(ClaudeSettings);

describe("ClientSettings desktop notifications and keep-awake", () => {
  it("keeps the fork's old banner toggles as optional inputs the patch never carries (#1032)", () => {
    expect(decodeClientSettings({})).not.toHaveProperty("desktopNotifyOnApproval");
    expect(decodeClientSettings({ desktopNotifyOnInput: false }).desktopNotifyOnInput).toBe(false);
    expect(decodeClientSettings({ desktopNotifyOnCompletion: true })).not.toHaveProperty(
      "desktopNotifyOnCompletion",
    );
    expect(decodeClientSettings({}).desktopBadgeAttention).toBe(true);
    expect(decodeClientSettingsPatch({ desktopNotifyOnHeld: false })).not.toHaveProperty(
      "desktopNotifyOnHeld",
    );
    expect(decodeClientSettingsPatch({ desktopBadgeAttention: false }).desktopBadgeAttention).toBe(
      false,
    );
  });

  it("keeps the desktop awake while a turn runs unless turned off (#1075)", () => {
    expect(decodeClientSettings({}).desktopKeepAwake).toBe(true);
    expect(decodeClientSettingsPatch({ desktopKeepAwake: false }).desktopKeepAwake).toBe(false);
  });
});

describe("ServerSettings project prompt snippets (#270 G)", () => {
  it("defaults to no snippets and decodes a per-project list", () => {
    expect(decodeServerSettings({}).projectPromptSnippets).toEqual({});
    const settings = decodeServerSettings({
      projectPromptSnippets: {
        "project-1": [{ id: "review", name: "Review", text: "Review the diff for bugs." }],
        "project-2": null,
      },
    });
    expect(settings.projectPromptSnippets["project-1" as never]).toEqual([
      { id: "review", name: "Review", text: "Review the diff for bugs." },
    ]);
    expect(settings.projectPromptSnippets["project-2" as never]).toBeNull();
  });

  it("refuses an oversized name and a blank body", () => {
    expect(() =>
      decodeServerSettingsPatch({
        projectPromptSnippets: {
          "project-1": [{ id: "x", name: "n".repeat(61), text: "body" }],
        },
      }),
    ).toThrow();
    expect(() =>
      decodeServerSettingsPatch({
        projectPromptSnippets: { "project-1": [{ id: "x", name: "Name", text: "   " }] },
      }),
    ).toThrow();
  });
});

describe("ClaudeSettings advisor model (#1232)", () => {
  it("is off until an instance names one", () => {
    expect(decodeClaudeSettings({}).advisorModel).toBe("");
    expect(decodeClaudeSettings({ advisorModel: " fable " }).advisorModel).toBe("fable");
  });

  it("takes a full model ID", () => {
    expect(decodeClaudeSettings({ advisorModel: "claude-fable-5-1" }).advisorModel).toBe(
      "claude-fable-5-1",
    );
  });
});
