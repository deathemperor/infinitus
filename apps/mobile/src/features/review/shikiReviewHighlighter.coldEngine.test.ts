import { afterAll, describe, expect, it, vi } from "vite-plus/test";

// Fork-only regression for infinitus#610. shiki gives every line a 500 ms
// tokenize budget (`tokenizeTimeLimit`) that textmate checks between scans.
// The JavaScript regex engine compiles its patterns lazily on first use, so a
// cold highlighter spends that budget compiling and, on a loaded CI runner,
// runs out mid-line: textmate then emits the rest of the line as one fused
// token, and the snippet path (patterns now compiled) disagrees with the
// source path. This makes the first scan look 600 ms long deterministically.

const coldScan = vi.hoisted(() => ({ clockSkewMs: 0, scans: 0 }));

vi.mock("@shikijs/engine-javascript", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@shikijs/engine-javascript")>();
  return {
    ...actual,
    createJavaScriptRegexEngine: (
      ...args: Parameters<typeof actual.createJavaScriptRegexEngine>
    ) => {
      const engine = actual.createJavaScriptRegexEngine(...args);
      return {
        createString: (s: string) => engine.createString(s),
        createScanner: (patterns: (string | RegExp)[]) => {
          const scanner = engine.createScanner(patterns);
          return {
            findNextMatchSync: (...scanArgs: Parameters<typeof scanner.findNextMatchSync>) => {
              if (coldScan.scans === 0) coldScan.clockSkewMs += 600;
              coldScan.scans += 1;
              return scanner.findNextMatchSync(...scanArgs);
            },
          };
        },
      };
    },
  };
});

const realNow = Date.now.bind(Date);
vi.spyOn(Date, "now").mockImplementation(() => realNow() + coldScan.clockSkewMs);

afterAll(() => {
  vi.restoreAllMocks();
});

describe("shikiReviewHighlighter on a cold regex engine", () => {
  it("tokenizes the first line fully even when its first scan outlives shiki's default budget", async () => {
    const highlighter = await import("./shikiReviewHighlighter");
    const source = "const answer: number = 42;";

    const highlighted = await highlighter.highlightSourceFile({
      path: "example.ts",
      contents: source,
      theme: "dark",
    });

    expect(coldScan.scans).toBeGreaterThan(0);
    const contents = highlighted.flat().map((token) => token.content);
    expect(contents.join("")).toBe(source);
    expect(contents).toContain("42");
    expect(
      await highlighter.highlightCodeSnippet({ code: source, language: "ts", theme: "dark" }),
    ).toEqual(highlighted);
  });
});
