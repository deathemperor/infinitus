import { describe, expect, it } from "@effect/vitest";
import * as NodeOS from "node:os";

import { piHomeEnvironment } from "./piHomeEnvironment.ts";

describe("piHomeEnvironment", () => {
  it("strips an ambient PI_CODING_AGENT_DIR", () => {
    // Oh My Pi is a fork of Pi that kept `APP_NAME = "pi"`, so it derives and
    // sets this very variable. Inheriting it would point both agents at one
    // directory and have each read the other's sessions.
    const env = piHomeEnvironment(
      { PATH: "/usr/bin", PI_CODING_AGENT_DIR: "/omp/home" },
      undefined,
    );
    expect(env.PI_CODING_AGENT_DIR).toBeUndefined();
    expect(env.PATH).toBe("/usr/bin");
  });

  it("an explicit home wins over an ambient one", () => {
    const env = piHomeEnvironment({ PI_CODING_AGENT_DIR: "/omp/home" }, "/pi/home");
    expect(env.PI_CODING_AGENT_DIR).toBe("/pi/home");
  });

  it("expands a leading ~, which spawn would otherwise pass verbatim", () => {
    const env = piHomeEnvironment({}, "~/.pi/agent");
    expect(env.PI_CODING_AGENT_DIR).toBe(`${NodeOS.homedir()}/.pi/agent`);
  });

  it("treats a blank home as unset rather than exporting an empty directory", () => {
    const env = piHomeEnvironment({ PI_CODING_AGENT_DIR: "/omp/home" }, "   ");
    expect(env.PI_CODING_AGENT_DIR).toBeUndefined();
  });
});
