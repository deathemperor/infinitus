#!/usr/bin/env python3
"""T3 CSS custom properties → Swift palettes (spec §3.1).

Reads tools/t3ref/upstream/{mobile-global.css,web-index.css,tailwind-theme.css},
resolves var(), oklch(), rgb(a), hex, --alpha(x / p%) and
color-mix(in srgb, A p%, B) to sRGB, writes
  Sources/InfinitusUI/T3/T3Theme.generated.swift
  Sources/InfinitusCore/T3/T3TailwindPalette.generated.swift
  tools/t3ref/upstream/tokens.resolved.json
Deterministic: same inputs → byte-identical outputs.
"""
import json, math, re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UP = ROOT / "tools/t3ref/upstream"
OUT_SWIFT = ROOT / "Sources/InfinitusUI/T3/T3Theme.generated.swift"
OUT_TAILWIND = ROOT / "Sources/InfinitusCore/T3/T3TailwindPalette.generated.swift"
OUT_JSON = UP / "tokens.resolved.json"

PROP = re.compile(r"^\s*(--[a-z0-9-]+)\s*:\s*(.+?);\s*$", re.M)

def block(text, start_pat, open_after=0):
    """Return the text of the {...} block whose opening brace follows the first match of start_pat."""
    m = re.search(start_pat, text)
    if not m: raise SystemExit(f"block not found: {start_pat}")
    i = text.index("{", m.end() + open_after)
    depth, j = 0, i
    while True:
        c = text[j]
        if c == "{": depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0: return text[i + 1:j]
        j += 1

def props(text):
    return {k: v.strip() for k, v in PROP.findall(text)}

def strip_nested(text):
    """Remove nested @variant/... blocks so only this level's props remain."""
    out, depth = [], 0
    for c in text:
        if c == "{": depth += 1; continue
        if c == "}": depth -= 1; continue
        if depth == 0: out.append(c)
    return "".join(out)

# ---- colour maths ---------------------------------------------------------
def clamp(x): return max(0.0, min(1.0, x))
def srgb_from_linear(c):
    return 12.92 * c if c <= 0.0031308 else 1.055 * (c ** (1 / 2.4)) - 0.055
def oklch_to_rgb(L, C, h):
    a = C * math.cos(math.radians(h)); b = C * math.sin(math.radians(h))
    l_ = L + 0.3963377774 * a + 0.2158037573 * b
    m_ = L - 0.1055613458 * a - 0.0638541728 * b
    s_ = L - 0.0894841775 * a - 1.2914855480 * b
    l, m, s = l_ ** 3, m_ ** 3, s_ ** 3
    r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
    g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
    bb = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
    return tuple(clamp(srgb_from_linear(clamp(x))) for x in (r, g, bb))

class Resolver:
    def __init__(self, scopes, contrast_alias_ok=False):
        self.scopes = scopes  # list of dicts, innermost first
        self.cache = {}
        # --contrast-X is a multi-line color-mix(…var(--appearance-contrast-base)…)
        # expression (CSS Color 4, not captured by the single-line PROP regex).
        # It algebraically reduces to plain X only while --appearance-contrast-base
        # is 100% and -boost/-border-boost are 0% — verified by the caller
        # (see contrast_identity_holds) before this flag is set, never assumed here.
        self.contrast_alias_ok = contrast_alias_ok
    def lookup(self, name):
        for s in self.scopes:
            if name in s: return s[name]
        if name.startswith("--contrast-") and self.contrast_alias_ok:
            return f"var(--{name[len('--contrast-'):]})"
        raise KeyError(name)
    def color(self, expr):
        expr = expr.strip()
        if expr in self.cache: return self.cache[expr]
        v = self._color(expr); self.cache[expr] = v; return v
    def _color(self, e):
        m = re.fullmatch(r"var\((--[a-z0-9-]+)\)", e)
        if m: return self.color(self.lookup(m.group(1)))
        if e in ("transparent",): return (0, 0, 0, 0.0)
        if e in ("white", "#fff", "#ffffff"): return (1, 1, 1, 1.0)
        if e in ("black", "#000", "#000000"): return (0, 0, 0, 1.0)
        m = re.fullmatch(r"#([0-9a-fA-F]{6})([0-9a-fA-F]{2})?", e)
        if m:
            h = m.group(1); a = int(m.group(2), 16) / 255 if m.group(2) else 1.0
            return (int(h[0:2], 16) / 255, int(h[2:4], 16) / 255, int(h[4:6], 16) / 255, a)
        m = re.fullmatch(r"rgba?\(\s*([\d.]+)[ ,]+([\d.]+)[ ,]+([\d.]+)\s*(?:[,/]\s*([\d.]+%?))?\s*\)", e)
        if m:
            a = m.group(4); a = (float(a[:-1]) / 100 if a and a.endswith("%") else float(a)) if a else 1.0
            return (float(m.group(1)) / 255, float(m.group(2)) / 255, float(m.group(3)) / 255, a)
        m = re.fullmatch(r"oklch\(\s*([\d.]+%?)\s+([\d.]+|none)\s+([\d.]+|none)\s*(?:/\s*([\d.]+%?))?\)", e)
        if m:
            L = m.group(1); L = float(L[:-1]) / 100 if L.endswith("%") else float(L)
            a = m.group(4); a = (float(a[:-1]) / 100 if a and a.endswith("%") else float(a)) if a else 1.0
            C = 0.0 if m.group(2) == "none" else float(m.group(2))
            H = 0.0 if m.group(3) == "none" else float(m.group(3))
            r, g, b = oklch_to_rgb(L, C, H)
            return (r, g, b, a)
        m = re.fullmatch(r"--alpha\(\s*(.+?)\s*/\s*([\d.]+)%\s*\)", e)
        if m:
            r, g, b, _ = self.color(m.group(1)); return (r, g, b, float(m.group(2)) / 100)
        m = re.fullmatch(r"color-mix\(in srgb,\s*(.+?)\s+([\d.]+)%\s*,\s*(.+?)(?:\s+([\d.]+)%)?\s*\)", e)
        if m:
            p1 = float(m.group(2)) / 100; p2 = float(m.group(4)) / 100 if m.group(4) else 1 - p1
            r1, g1, b1, a1 = self.color(m.group(1)); r2, g2, b2, a2 = self.color(m.group(3))
            t = p2 / (p1 + p2)  # CSS: weights normalised
            # CSS Color 4 interpolates premultiplied, so mixing toward
            # transparent keeps the opaque colour's RGB, only fading alpha.
            a = (1 - t) * a1 + t * a2
            def mix(x1, x2): return ((1 - t) * x1 * a1 + t * x2 * a2) / a if a > 0 else 0.0
            return (mix(r1, r2), mix(g1, g2), mix(b1, b2), a)
        raise ValueError(f"unsupported colour expression: {e}")

def to255(c):
    r, g, b, a = c
    return [round(r * 255), round(g * 255), round(b * 255), round(a, 4)]

def camel(name, strip):
    n = name[len(strip):] if name.startswith(strip) else name.lstrip("-")
    parts = n.split("-")
    return parts[0] + "".join(p[:1].upper() + p[1:] for p in parts[1:])

# appearance- also covers --appearance-contrast-target (black/white): a
# formula input for the --contrast-* family, never a UI token itself.
NON_COLOUR = re.compile(r"^--(radius|font-|animate-|glass-|app-scrollbar-width|sidebar-content-inset|sidebar-control-gap|sidebar-row-content-inset|command-|floating-content-inset|desktop-window|workspace-|appearance-|control-radius|surface-grain)")

def contrast_identity_holds(css):
    """True only while --contrast-X == X holds algebraically: the metrics
    `:root` block's --appearance-contrast-base is 100% and both
    -boost/-border-boost are 0% (T3's CSS as of VERSIONS, never overridden).
    If upstream ever changes these, the Resolver.lookup alias must not fire —
    callers should fail loudly instead (see web())."""
    root = props(strip_nested(block(css, r":root\s*")))
    return (root.get("--appearance-contrast-base"),
            root.get("--appearance-contrast-boost"),
            root.get("--appearance-contrast-border-boost")) == ("100%", "0%", "0%")

def mobile():
    css = (UP / "mobile-global.css").read_text()
    root = block(css, r"@layer theme\s*")
    root = block(root, r":root\s*")
    light = props(strip_nested(block(root, r"@variant light\s*")))
    dark = props(strip_nested(block(root, r"@variant dark\s*")))
    out = {}
    for label, scope in (("mobileLight", light), ("mobileDark", dark)):
        r = Resolver([scope])
        out[label] = {camel(k, "--color-"): to255(r.color(v)) for k, v in scope.items() if k.startswith("--color-")}
    return out

def web():
    css = (UP / "web-index.css").read_text()
    if not contrast_identity_holds(css):
        raise SystemExit(
            "--appearance-contrast-base/-boost/-border-boost are no longer "
            "100%/0%/0% in web-index.css: the --contrast-X == X alias in "
            "Resolver.lookup no longer holds. Implement real var()-in-"
            "percentage color-mix support instead of the alias."
        )
    # web-index.css layers a few of its own `--color-*` tokens (e.g. zinc-25,
    # a shade Tailwind's own theme.css doesn't define) on top of Tailwind's
    # default theme via `@theme inline { … }`.
    theme = {**props(block((UP / "tailwind-theme.css").read_text(), r"@theme\s+default\s*")),
             **props(strip_nested(block(css, r"@theme\s+inline\s*")))}
    # the default theme root: the `:root {` whose first line is `color-scheme: light;`
    m = re.search(r":root\s*\{\s*\n\s*color-scheme:\s*light;", css)
    body = block(css[m.start():], r":root\s*")
    light = props(strip_nested(body))
    dark_over = props(strip_nested(block(body, r"@variant dark\s*")))
    sb = block(css, r"\[data-app-sidebar\]\s*")
    sb_light = props(strip_nested(sb)); sb_dark = props(strip_nested(block(sb, r"@variant dark\s*")))
    out = {}
    # [data-app-sidebar] overrides only apply to the sidebar* tokens (that is
    # what the sidebar renders with); other tokens keep the plain :root
    # cascade even though the sidebar block redeclares generic names like
    # --background to compute its own formulas from.
    for label, base_scopes, sidebar_scopes, keys in (
        ("webLight", [light, theme], [sb_light, light, theme], {**light, **sb_light}),
        ("webDark", [dark_over, light, theme], [sb_dark, dark_over, sb_light, light, theme],
         {**light, **dark_over, **sb_light, **sb_dark}),
    ):
        r_base = Resolver(base_scopes, contrast_alias_ok=True)
        r_sidebar = Resolver(sidebar_scopes, contrast_alias_ok=True)
        pal = {}
        for k in keys:
            if NON_COLOUR.match(k) or k.startswith("--color-"): continue
            r = r_sidebar if k.startswith("--sidebar") else r_base
            try:
                pal[camel(k, "--")] = to255(r.color(r.lookup(k)))
            except (ValueError, KeyError) as e:
                raise SystemExit(f"{label} {k}: cannot resolve to a colour ({e}) — extend the resolver, don't skip it")
        out[label] = pal
    return out

def swift(tokens):
    lines = ["// Generated by tools/t3ref/gen-tokens.py — do not edit. Inputs: tools/t3ref/upstream (see VERSIONS).",
             "import SwiftUI", "", "public enum T3Theme {"]
    keys = {"mobile": sorted(tokens["mobileLight"]), "web": sorted(tokens["webLight"])}
    for plat in ("mobile", "web"):
        name = "MobilePalette" if plat == "mobile" else "WebPalette"
        lines.append(f"    public struct {name}: Sendable {{")
        for k in keys[plat]: lines.append(f"        public let {k}: T3RGBA")
        lines.append("    }")
        for scheme in ("Light", "Dark"):
            lines.append(f"    public static let {plat}{scheme} = {name}(")
            vals = tokens[f"{plat}{scheme}"]
            lines.append(",\n".join(f"        {k}: T3RGBA({vals[k][0]}, {vals[k][1]}, {vals[k][2]}, {vals[k][3]})" for k in keys[plat]))
            lines.append("    )")
    lines += ["    public enum Metrics {",
              "        public static let radius: Double = 10", "        public static let controlRadius: Double = 8",
              "        public static let sidebarWidth: Double = 256",
              "        // `--sidebar-width-icon`. Unused by the Mac window: its sidebar is",
              "        // `collapsible=\"offcanvas\"` (AppSidebarLayout.tsx:227), which collapses",
              "        // to width 0 (ui/sidebar.tsx:285), never to an icon rail.",
              "        public static let sidebarWidthIcon: Double = 48",
              "        public static let topbarHeight: Double = 52", "        public static let sidebarContentInset: Double = 8",
              "        public static let sidebarRowContentInset: Double = 10", "        public static let scrollbarWidth: Double = 6",
              "    }", "}", ""]
    return "\n".join(lines)

# ---- Tailwind palette stops ----------------------------------------------
# Every `--color-{hue}-{shade}` the Swift code names, and nothing else. Two
# call sites drive the list:
#   * T3ProjectIcon.colorByName — `projectIconColors.ts`'s PROJECT_ICON_COLORS,
#     a text-{hue}-600 / dark:text-{hue}-400 pair per icon.
#   * T3ThreadRowView — `Sidebar.tsx:1127,1141,1147,1153,1165`'s topStatus
#     classNames (sky-600/400, amber-700/300, indigo-600/300, red-700/300,
#     emerald-700/300) and `:1608`'s snoozed wake label (blue-600/400).
# Add a name here when Swift starts naming it; never hand-type a stop.
ICON_HUES = ["amber", "blue", "cyan", "emerald", "fuchsia", "green", "indigo", "lime",
             "orange", "pink", "purple", "red", "rose", "sky", "teal", "violet", "yellow"]
STOPS = sorted({(h, s) for h in ICON_HUES for s in (400, 600)}
               | {("sky", 600), ("sky", 400), ("amber", 700), ("amber", 300),
                  ("indigo", 600), ("indigo", 300), ("red", 700), ("red", 300),
                  ("emerald", 700), ("emerald", 300)})

def tailwind():
    """The pinned tailwindcss@4.3.3 `@theme default` block's oklch stops,
    resolved to sRGB by the same oklch_to_rgb every other token goes through."""
    theme = props(block((UP / "tailwind-theme.css").read_text(), r"@theme\s+default\s*"))
    r = Resolver([theme])
    out = {}
    for hue, shade in STOPS:
        key = f"--color-{hue}-{shade}"
        if key not in theme:
            raise SystemExit(f"{key} is not in tools/t3ref/upstream/tailwind-theme.css — re-vendor or fix the name")
        rr, gg, bb, _ = r.color(theme[key])
        out[f"{hue}{shade}"] = [round(rr * 255), round(gg * 255), round(bb * 255)]
    return out

def tailwind_swift(stops):
    lines = ["// Generated by tools/t3ref/gen-tokens.py \u2014 do not edit. Inputs: tools/t3ref/upstream (see VERSIONS).",
             "",
             "/// The pinned tailwindcss@4.3.3 palette stops the T3 port names, resolved",
             "/// from `theme.css`'s `oklch()` definitions to sRGB. v4's stops are NOT v3's",
             "/// hex values (e.g. sky-400 is oklch(74.6% 0.16 232.661), not #38bdf8) \u2014 the",
             "/// generator is the only place these numbers may come from.",
             "public enum T3Tailwind {"]
    for k in sorted(stops):
        r, g, b = stops[k]
        lines.append(f"    public static let {k} = T3ProjectIcon.RGB({r}, {g}, {b})")
    lines += ["}", ""]
    return "\n".join(lines)

def main():
    tokens = {**mobile(), **web()}
    OUT_JSON.write_text(json.dumps(tokens, indent=1, sort_keys=True) + "\n")
    OUT_SWIFT.write_text(swift(tokens))
    stops = tailwind()
    OUT_TAILWIND.write_text(tailwind_swift(stops))
    print(f"wrote {OUT_SWIFT.relative_to(ROOT)} ({sum(len(v) for v in tokens.values())} tokens)")
    print(f"wrote {OUT_TAILWIND.relative_to(ROOT)} ({len(stops)} stops)")

if __name__ == "__main__": main()
