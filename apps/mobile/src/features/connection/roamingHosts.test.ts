import {
  BearerConnectionProfile,
  BearerConnectionTarget,
} from "@t3tools/client-runtime/connection";
import { EnvironmentId } from "@t3tools/contracts";
import * as Option from "effect/Option";
import { describe, expect, it } from "vite-plus/test";

import { roamingHostsLine } from "./roamingHosts";

const environmentId = EnvironmentId.make("environment-1");
const target = new BearerConnectionTarget({
  environmentId,
  label: "Mac",
  connectionId: "bearer:1",
});
const entry = (over: Partial<ConstructorParameters<typeof BearerConnectionProfile>[0]> = {}) => ({
  target,
  profile: Option.some(
    new BearerConnectionProfile({
      connectionId: "bearer:1",
      environmentId,
      label: "Mac",
      httpBaseUrl: "http://192.168.100.61:3773",
      wsBaseUrl: "ws://192.168.100.61:3773",
      ...over,
    }),
  ),
  enabled: true,
});

describe("roamingHostsLine", () => {
  it("says nothing for a one-host environment or none at all", () => {
    expect(roamingHostsLine(null)).toBeNull();
    expect(roamingHostsLine(entry())).toBeNull();
    expect(roamingHostsLine({ target, profile: Option.none(), enabled: true })).toBeNull();
  });

  it("names the door tried first, and the one in use once it answered", () => {
    expect(roamingHostsLine(entry({ alternateHttpBaseUrls: ["https://code.infinitus.run"] }))).toBe(
      "Tries https://code.infinitus.run first",
    );
    expect(
      roamingHostsLine(
        entry({
          alternateHttpBaseUrls: ["https://code.infinitus.run"],
          lastGoodHttpBaseUrl: "https://code.infinitus.run",
        }),
      ),
    ).toBe("Connected via https://code.infinitus.run");
    expect(
      roamingHostsLine(
        entry({
          alternateHttpBaseUrls: ["https://code.infinitus.run"],
          lastGoodHttpBaseUrl: "http://192.168.100.61:3773",
        }),
      ),
    ).toBe("Tries https://code.infinitus.run first");
  });
});
