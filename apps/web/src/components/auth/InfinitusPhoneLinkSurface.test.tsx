import { act } from "react";
import { create, type ReactTestRenderer } from "react-test-renderer";
import { describe, expect, it } from "vite-plus/test";

import { InfinitusPhoneLinkSurface } from "./InfinitusPhoneLinkSurface";

function text(renderer: ReactTestRenderer): string {
  const walk = (node: unknown): string => {
    if (typeof node === "string") return node;
    if (Array.isArray(node)) return node.map(walk).join("");
    if (node !== null && typeof node === "object" && "children" in node) {
      return walk((node as { children: unknown }).children);
    }
    return "";
  };
  return walk(renderer.toJSON());
}

describe("InfinitusPhoneLinkSurface", () => {
  it("sends the reader to the app and promises the code is unspent, with no form to submit it", () => {
    let renderer: ReactTestRenderer | undefined;
    act(() => {
      renderer = create(<InfinitusPhoneLinkSurface />);
    });
    const shown = text(renderer!);
    expect(shown).toContain("This link is for the Infinitus phone app");
    expect(shown).toContain("Settings › Configuration › Environments › Add › Scan QR");
    expect(shown).toContain("the code is still good");
    expect(renderer!.root.findAll((node) => node.type === "form" || node.type === "input")).toEqual(
      [],
    );
    act(() => renderer!.unmount());
  });
});
