import { describe, expect, it } from "vite-plus/test";

import { carryTranslations, translationsByEnglish } from "./infinitus-rename-catalogs.ts";

describe("infinitus-rename-catalogs", () => {
  it("gives a re-keyed string the translation its English had", () => {
    const before = translationsByEnglish(
      { old: "Restart Infinitus.", kept: "Retry", same: "Infinitus" },
      { old: "Infinitus neu starten.", kept: "Erneut versuchen", same: "Infinitus" },
    );
    const english = { moved: "Restart Infinitus.", kept: "Retry", added: "New copy" };
    expect(
      carryTranslations(
        english,
        { moved: "Restart Infinitus.", kept: "Erneut", added: "New copy" },
        before,
      ),
    ).toEqual({ moved: "Infinitus neu starten.", kept: "Erneut", added: "New copy" });
  });
});
