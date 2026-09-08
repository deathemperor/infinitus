#!/usr/bin/env python3
"""lucide icon nodes → Swift path data (spec §3.3). Each *.js under
tools/t3ref/upstream/lucide holds `__iconNode = [["path", {d: …}], ["circle", {cx,cy,r}], …]`,
pretty-printed across multiple lines for longer `d` strings. Every
element becomes an SVG path string; the Swift enum case is the
lowerCamel of the file name. Deterministic.

The set of icons that get a Swift case is driven by NAMES (the PascalCase
component names T3 imports from lucide-react), not by globbing every
vendored .js — some vendored files exist only to resolve a re-export (see
below) and must not get their own case.

Kebab-case mapping exceptions (a trailing digit gets its own dash, which
the generic camelCase→kebab-case regex misses): Code2 → code-2,
FolderGit2 → folder-git-2, Globe2 → globe-2, Link2 → link-2,
Maximize2 → maximize-2, Minimize2 → minimize-2, MousePointer2 → mouse-pointer-2,
PictureInPicture2 → picture-in-picture-2, Trash2 → trash-2, Undo2 → undo-2,
Unlink2 → unlink-2.

Five vendored names are deprecated lucide aliases whose upstream .js is a
byte-identical `export { default } from './<target>.js'` re-export with
no __iconNode of its own: code-2 → code-xml, globe-2 → earth,
more-vertical → ellipsis-vertical, x-circle → circle-x,
message-circle-question → message-circle-question-mark. Both the alias
file and its target module are vendored as true upstream copies (so a
future `cp` re-vendor never has to special-case them); this generator
follows the re-export at parse time and draws the target's paths under
the alias's own case name (e.g. `Lucide.code2` renders code-xml's glyph,
same as lucide-react's `Code2` does). A future re-vendor must remember to
also copy each alias's target module — grep vendored files for
`export { default } from` to find which ones need a target alongside them.
"""
import json, re
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "tools/t3ref/upstream/lucide"
NAMES = ROOT / "tools/t3ref/upstream/lucide/NAMES"
OUT = ROOT / "Sources/InfinitusUI/T3/Lucide.generated.swift"

# Whitespace-tolerant: lucide pretty-prints longer nodes as
# `[\n    "path",\n    {\n      d: "…",\n      key: "…"\n    }\n  ]`.
NODE = re.compile(r'\[\s*"(\w+)"\s*,\s*\{([^}]*)\}\s*\]')
ATTR = re.compile(r'(\w+):\s*"([^"]*)"')
REEXPORT = re.compile(r"export \{ default \} from '\./(\S+)\.js'")

KEBAB_OVERRIDES = {
    "Code2": "code-2", "FolderGit2": "folder-git-2", "Globe2": "globe-2", "Link2": "link-2",
    "Maximize2": "maximize-2", "Minimize2": "minimize-2", "MousePointer2": "mouse-pointer-2",
    "PictureInPicture2": "picture-in-picture-2", "Trash2": "trash-2", "Undo2": "undo-2", "Unlink2": "unlink-2",
}

def kebab(name):
    if name in KEBAB_OVERRIDES: return KEBAB_OVERRIDES[name]
    s = re.sub(r"([a-z0-9])([A-Z])", r"\1-\2", name)
    s = re.sub(r"([A-Z])([A-Z][a-z])", r"\1-\2", s)
    return s.lower()

def path_for(tag, a):
    f = lambda k: float(a[k])
    if tag == "path": return a["d"]
    if tag == "circle":
        cx, cy, r = f("cx"), f("cy"), f("r")
        return f"M{cx - r} {cy}a{r} {r} 0 1 0 {2 * r} 0a{r} {r} 0 1 0 {-2 * r} 0"
    if tag == "ellipse":
        cx, cy, rx, ry = f("cx"), f("cy"), f("rx"), f("ry")
        return f"M{cx - rx} {cy}a{rx} {ry} 0 1 0 {2 * rx} 0a{rx} {ry} 0 1 0 {-2 * rx} 0"
    if tag == "rect":
        x, y, w, h = f("x"), f("y"), f("width"), f("height"); r = float(a.get("rx", 0))
        if r == 0: return f"M{x} {y}h{w}v{h}h{-w}z"
        return (f"M{x + r} {y}h{w - 2 * r}a{r} {r} 0 0 1 {r} {r}v{h - 2 * r}a{r} {r} 0 0 1 {-r} {r}"
                f"h{-(w - 2 * r)}a{r} {r} 0 0 1 {-r} {-r}v{-(h - 2 * r)}a{r} {r} 0 0 1 {r} {-r}z")
    if tag == "line": return f"M{f('x1')} {f('y1')}L{f('x2')} {f('y2')}"
    if tag in ("polyline", "polygon"):
        pts = [p for p in re.split(r"[ ,]+", a["points"].strip()) if p]
        d = "M" + " ".join(pts[0:2]) + "".join(f"L{pts[i]} {pts[i + 1]}" for i in range(2, len(pts), 2))
        return d + ("z" if tag == "polygon" else "")
    raise SystemExit(f"unsupported element {tag}")

def camel(name):
    parts = name.split("-")
    s = parts[0] + "".join(p[:1].upper() + p[1:] for p in parts[1:])
    return s if not s[0].isdigit() else "_" + s

def module_text(stem):
    """The vendored module's own text, following one re-export hop if
    it has no __iconNode of its own. Returns (node_body, text_for_key_count)."""
    js = SRC / f"{stem}.js"
    if not js.exists(): raise SystemExit(f"{stem}: not vendored ({js} missing)")
    text = js.read_text()
    m = re.search(r"__iconNode = \[(.*?)\];", text, re.S)
    if m: return m.group(1), text
    re_m = REEXPORT.search(text)
    if not re_m: raise SystemExit(f"{stem}: no __iconNode and no re-export in {js.name}")
    target = re_m.group(1)
    target_js = SRC / f"{target}.js"
    if not target_js.exists(): raise SystemExit(f"{stem}: re-export target '{target}.js' not vendored alongside it")
    target_text = target_js.read_text()
    tm = re.search(r"__iconNode = \[(.*?)\];", target_text, re.S)
    if not tm: raise SystemExit(f"{stem}: re-export target '{target}.js' has no __iconNode either")
    return tm.group(1), target_text

names = [l.strip() for l in NAMES.read_text().splitlines() if l.strip()]
stems = sorted({kebab(n) for n in names})

icons = []
for stem in stems:
    node_body, text_for_count = module_text(stem)
    elements = NODE.findall(node_body)
    key_count = text_for_count.count("key:")
    if len(elements) < key_count:
        raise SystemExit(f"{stem}: parsed {len(elements)} of {key_count} node elements — NODE regex under-matched")
    if not elements:
        raise SystemExit(f"{stem}: zero node elements parsed")
    paths = [path_for(tag, dict(ATTR.findall(attrs))) for tag, attrs in elements]
    icons.append((stem, paths))

lines = ["// Generated by tools/t3ref/gen-lucide.py — do not edit. lucide-react 0.564.0, ISC (tools/t3ref/upstream/LICENSE.lucide).",
         "public enum Lucide: String, CaseIterable, Sendable {"]
lines += [f'    case {camel(n)} = "{n}"' for n, _ in icons]
lines += ["", "    /// SVG path data in the 24×24 view box, one entry per element.", "    public var paths: [String] {", "        switch self {"]
lines += [f'        case .{camel(n)}: return {json.dumps(p)}' for n, p in icons]
lines += ["        }", "    }", "}", ""]
OUT.write_text("\n".join(lines))
print(f"wrote {OUT.relative_to(ROOT)} ({len(icons)} icons)")
