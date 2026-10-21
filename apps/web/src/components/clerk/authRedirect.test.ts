import { describe, expect, it } from "vite-plus/test";

import { resolveClerkSignInProps } from "./authRedirect";

describe("resolveClerkSignInProps", () => {
  it("removes a Clerk virtual pathname and callback params while preserving the desktop route", () => {
    expect(
      resolveClerkSignInProps(
        "infinitus://app/CLERK-ROUTER/VIRTUAL/sign-up?__clerk_status=complete#/settings/connections",
        true,
      ),
    ).toEqual({
      forceRedirectUrl: "infinitus://app/#/settings/connections",
      signUpForceRedirectUrl: "infinitus://app/#/settings/connections",
    });
  });
<<<<<<< HEAD

  it("preserves a clean development desktop route", () => {
    expect(resolveClerkSignInProps("infinitus-dev://app/#/settings/general", true)).toEqual({
      forceRedirectUrl: "infinitus-dev://app/#/settings/general",
      signUpForceRedirectUrl: "infinitus-dev://app/#/settings/general",
    });
  });
=======
>>>>>>> upstream-sync-4f651cb10-upstream-renamed
});
