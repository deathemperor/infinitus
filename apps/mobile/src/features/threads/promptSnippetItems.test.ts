import type { PromptSnippet } from "@t3tools/contracts";
import { describe, expect, it } from "vite-plus/test";

import { promptSnippetCommandItems, promptSnippetPreview } from "./promptSnippetItems";

const review: PromptSnippet = { id: "review", name: "Review", text: "Review the diff.\nBe terse." };
const tests: PromptSnippet = { id: "tests", name: "Add tests", text: "Add tests." };

describe("promptSnippetItems (#270 G, phone)", () => {
  it("lists every snippet on an empty query and filters by name otherwise", () => {
    expect(promptSnippetCommandItems([review, tests], "").map((item) => item.id)).toEqual([
      "prompt:review",
      "prompt:tests",
    ]);
    expect(promptSnippetCommandItems([review, tests], "/TEST").map((item) => item.id)).toEqual([
      "prompt:tests",
    ]);
    expect(promptSnippetCommandItems([review, tests], "prompt:rev")[0]).toMatchObject({
      type: "prompt-snippet",
      label: "Review",
      description: "Review the diff.",
      snippet: review,
    });
    expect(promptSnippetCommandItems([review, tests], "zzz")).toEqual([]);
  });

  it("previews the first line, cut with an ellipsis", () => {
    expect(promptSnippetPreview("x".repeat(100), 10)).toBe("xxxxxxxxx…");
  });
});
