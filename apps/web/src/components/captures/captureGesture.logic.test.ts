import type { EnvironmentId, ProjectId } from "@t3tools/contracts";
import { describe, expect, it } from "vite-plus/test";

import { captureGestureFailureMessage, resolveCaptureGestureProject } from "./captureGesture.logic";

const project = (id: string) => ({
  environmentId: "env" as EnvironmentId,
  projectId: id as ProjectId,
});

describe("resolveCaptureGestureProject", () => {
  it("prefers the routed project, then the last one a gesture reached", () => {
    expect(resolveCaptureGestureProject(project("a"), project("b"))).toEqual(project("a"));
    expect(resolveCaptureGestureProject(null, project("b"))).toEqual(project("b"));
    expect(resolveCaptureGestureProject(null, null)).toBeNull();
  });
});

describe("captureGestureFailureMessage", () => {
  it("names the fix for a missing grant and describes the rest", () => {
    expect(captureGestureFailureMessage("accessibility")).toContain("Accessibility");
    expect(captureGestureFailureMessage("no-focus")).toContain("focused");
    expect(captureGestureFailureMessage("unsupported")).toContain("selection");
    expect(captureGestureFailureMessage("timeout")).toContain("too long");
    expect(captureGestureFailureMessage("helper")).toContain("could not be read");
  });
});
