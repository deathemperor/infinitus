import { describe, expect, it, vi } from "vite-plus/test";

import {
  findDeepLinkArgument,
  MAX_DEEP_LINK_PROMPT_LENGTH,
  makeDeepLinkIntake,
  parseDesktopDeepLink,
  type DeepLinkIntakeApp,
  type DeepLinkIntakeEvent,
} from "./InfinitusDeepLinks.ts";

describe("parseDesktopDeepLink (#270 D)", () => {
  it("routes thread links", () => {
    expect(parseDesktopDeepLink("infinitus://thread/env-1/thread-9", "infinitus")).toEqual({
      kind: "thread",
      environmentId: "env-1",
      threadId: "thread-9",
    });
    expect(parseDesktopDeepLink("infinitus://thread/env%201/t/", "infinitus")).toEqual({
      kind: "thread",
      environmentId: "env 1",
      threadId: "t",
    });
  });

  it("opens the composer with the project and the prompt", () => {
    expect(
      parseDesktopDeepLink(
        "infinitus://new?project=Infinitus&prompt=fix%20the%20flaky%20test",
        "infinitus",
      ),
    ).toEqual({ kind: "new", project: "Infinitus", prompt: "fix the flaky test" });
    expect(parseDesktopDeepLink("infinitus://new/?project=x", "infinitus")).toEqual({
      kind: "new",
      project: "x",
      prompt: "",
    });
  });

  it("cuts a prompt at the cap", () => {
    const prompt = "a".repeat(MAX_DEEP_LINK_PROMPT_LENGTH + 5);
    const link = parseDesktopDeepLink(`infinitus://new?project=p&prompt=${prompt}`, "infinitus");
    expect(link?.kind === "new" ? link.prompt.length : null).toBe(MAX_DEEP_LINK_PROMPT_LENGTH);
  });

  it("claims nothing else", () => {
    expect(parseDesktopDeepLink("infinitus://app/index.html", "infinitus")).toBeNull();
    expect(parseDesktopDeepLink("infinitus://join/abc", "infinitus")).toBeNull();
    expect(parseDesktopDeepLink("infinitus-dev://thread/e/t", "infinitus")).toBeNull();
    expect(parseDesktopDeepLink("infinitus://thread/e", "infinitus")).toBeNull();
    expect(parseDesktopDeepLink("infinitus://thread/e/t/extra", "infinitus")).toBeNull();
    expect(parseDesktopDeepLink("infinitus://thread/%E0%A4%A/t", "infinitus")).toBeNull();
    expect(parseDesktopDeepLink("infinitus://new?prompt=only", "infinitus")).toBeNull();
    expect(parseDesktopDeepLink("infinitus://new/more?project=p", "infinitus")).toBeNull();
    expect(parseDesktopDeepLink("infinitus:thread/e/t", "infinitus")).toBeNull();
    expect(parseDesktopDeepLink("not a url", "infinitus")).toBeNull();
  });
});

describe("findDeepLinkArgument (#270 D)", () => {
  it("takes the last argv entry that is a link of ours", () => {
    expect(
      findDeepLinkArgument(
        ["/app/infinitus", "--flag", "infinitus://app/x", "infinitus://thread/e/t"],
        "infinitus",
      ),
    ).toBe("infinitus://thread/e/t");
    expect(findDeepLinkArgument(["/app/infinitus", "infinitus://app/x"], "infinitus")).toBeNull();
  });
});

describe("deep link intake (#270 D)", () => {
  function app() {
    type Listener = (event: DeepLinkIntakeEvent, payload: string | string[]) => void;
    const listeners = new Map<string, Listener>();
    const fake: DeepLinkIntakeApp = {
      on: (
        event: "open-url" | "second-instance",
        listener:
          | ((event: DeepLinkIntakeEvent, url: string) => void)
          | ((event: DeepLinkIntakeEvent, argv: string[]) => void),
      ) => {
        listeners.set(event, listener as Listener);
      },
    };
    const emit = (event: "open-url" | "second-instance", payload: string | string[]) => {
      const preventDefault = vi.fn();
      listeners.get(event)?.({ preventDefault }, payload);
      return preventDefault;
    };
    return { fake, emit };
  }

  it("holds a link caught before the service drains, then streams the rest", () => {
    const { fake, emit } = app();
    const intake = makeDeepLinkIntake();
    intake.attach(fake, ["/app"], "infinitus");
    expect(emit("open-url", "infinitus://thread/e/t")).toHaveBeenCalledOnce();
    const seen: string[] = [];
    intake.drain((url) => seen.push(url));
    expect(seen).toEqual(["infinitus://thread/e/t"]);
    emit("second-instance", ["/app", "infinitus://new?project=p"]);
    expect(seen).toEqual(["infinitus://thread/e/t", "infinitus://new?project=p"]);
  });

  it("keeps only the latest link while nobody listens", () => {
    const { fake, emit } = app();
    const intake = makeDeepLinkIntake();
    intake.attach(fake, ["/app", "infinitus://thread/e/first"], "infinitus");
    emit("open-url", "infinitus://thread/e/second");
    const seen: string[] = [];
    intake.drain((url) => seen.push(url));
    expect(seen).toEqual(["infinitus://thread/e/second"]);
  });

  it("leaves other URLs to their own handlers", () => {
    const { fake, emit } = app();
    const intake = makeDeepLinkIntake();
    intake.attach(fake, ["/app"], "infinitus");
    expect(emit("open-url", "infinitus://app/clerk-callback?code=1")).not.toHaveBeenCalled();
    expect(emit("open-url", "infinitus://join/abc")).not.toHaveBeenCalled();
    const seen: string[] = [];
    intake.drain((url) => seen.push(url));
    expect(seen).toEqual([]);
  });
});
