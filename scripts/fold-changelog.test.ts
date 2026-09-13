import { describe, expect, it } from "vite-plus/test";

import { foldChangelog } from "./fold-changelog.mjs";

const HEAD = "# Changelog\n\nNotes.\n\n";

describe("foldChangelog", () => {
  it("moves Unreleased and the fragments into one section, surfaces in fixed order", () => {
    const changelog = `${HEAD}## Unreleased\n\n### Desktop\n- Old desktop line.\n\n## 0.5.0-alpha.8\n\n### Mac\n- Shipped.\n`;
    const fragments: Array<[string, string]> = [
      ["1130.md", "Mac: The Team features are gone.\nPhone: The chip is quieter.\n"],
      ["1131.md", "Desktop: - Worktree branches are named infinitus/….\n"],
    ];
    const { text, warnings } = foldChangelog(changelog, fragments, "0.5.0-alpha.9");
    expect(warnings).toEqual([]);
    expect(text).toBe(
      `${HEAD}## Unreleased\n\n\n## 0.5.0-alpha.9\n\n` +
        `### Mac\n- The Team features are gone.\n\n` +
        `### Desktop\n- Old desktop line.\n- Worktree branches are named infinitus/….\n\n` +
        `### Phone\n- The chip is quieter.\n\n` +
        `## 0.5.0-alpha.8\n\n### Mac\n- Shipped.\n`,
    );
  });

  it("keeps an unrecognised fragment line under Desktop and says so", () => {
    const changelog = `${HEAD}## Unreleased\n\n## 0.5.0-alpha.8\n\n- x\n`;
    const { text, warnings } = foldChangelog(
      changelog,
      [["odd.md", "Just a sentence.\n"]],
      "0.5.0-alpha.9",
    );
    expect(warnings).toHaveLength(1);
    expect(text).toContain("### Desktop\n- Just a sentence.\n");
  });

  it("refuses an empty release", () => {
    expect(() =>
      foldChangelog(`${HEAD}## Unreleased\n\n## 0.5.0-alpha.8\n`, [], "0.5.0-alpha.9"),
    ).toThrow(/nothing to release/);
  });
});
