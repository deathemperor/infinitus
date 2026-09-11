import { DEFAULT_SERVER_SETTINGS, ProjectId, type PromptSnippet } from "@t3tools/contracts";
import { describe, expect, it } from "vite-plus/test";

import {
  nextPromptSnippetId,
  promptSnippetDraft,
  promptSnippetPreview,
  promptSnippetsPatch,
  removePromptSnippet,
  snippetsForProject,
  upsertPromptSnippet,
} from "./promptSnippets.logic";

const project = ProjectId.make("project-1");
const review: PromptSnippet = { id: "review", name: "Review", text: "Review the diff.\nBe terse." };

describe("promptSnippets.logic (#270 G)", () => {
  it("reads a project's list, empty when absent or cleared", () => {
    expect(snippetsForProject(DEFAULT_SERVER_SETTINGS, project)).toEqual([]);
    expect(snippetsForProject({ projectPromptSnippets: { [project]: null } }, project)).toEqual([]);
    expect(snippetsForProject({ projectPromptSnippets: { [project]: [review] } }, project)).toEqual(
      [review],
    );
  });

  it("trims a draft and refuses blanks and oversizes", () => {
    expect(promptSnippetDraft("  Review ", " body ")).toEqual({ name: "Review", text: "body" });
    expect(promptSnippetDraft("", "body")).toBeNull();
    expect(promptSnippetDraft("Name", "   ")).toBeNull();
    expect(promptSnippetDraft("n".repeat(61), "body")).toBeNull();
    expect(promptSnippetDraft("Name", "b".repeat(8_193))).toBeNull();
  });

  it("mints ids from the name and suffixes past taken ones", () => {
    expect(nextPromptSnippetId("Review the diff!", [])).toBe("review-the-diff");
    expect(nextPromptSnippetId("Review", ["review", "review-2"])).toBe("review-3");
    expect(nextPromptSnippetId("???", [])).toBe("snippet");
  });

  it("upserts by id, removes by id and caps the list at 50", () => {
    const tests: PromptSnippet = { id: "tests", name: "Tests", text: "Add tests." };
    const added = upsertPromptSnippet([review], tests);
    expect(added).toEqual([review, tests]);
    const edited = upsertPromptSnippet(added!, { ...review, text: "Review it." });
    expect(edited?.map((item) => item.text)).toEqual(["Review it.", "Add tests."]);
    expect(removePromptSnippet(edited!, "review")).toEqual([tests]);
    const full = Array.from({ length: 50 }, (_, index) => ({ ...review, id: `s${index}` }));
    expect(upsertPromptSnippet(full, tests)).toBeNull();
    expect(upsertPromptSnippet(full, { ...full[0]!, name: "Renamed" })).toHaveLength(50);
  });

  it("builds the patch, clearing the entry for an empty list", () => {
    expect(promptSnippetsPatch(project, [review])).toEqual({
      projectPromptSnippets: { [project]: [review] },
    });
    expect(promptSnippetsPatch(project, [])).toEqual({
      projectPromptSnippets: { [project]: null },
    });
  });

  it("previews the first line, cut with an ellipsis", () => {
    expect(promptSnippetPreview(review.text)).toBe("Review the diff.");
    expect(promptSnippetPreview("x".repeat(100), 10)).toBe("xxxxxxxxx…");
  });
});
