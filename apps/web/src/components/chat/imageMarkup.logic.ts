/**
 * Fork (#875): the drawing model behind the composer's image markup editor.
 * Pure — the dialog owns the canvas, this owns the geometry and the shape
 * list, so both can be tested without a DOM.
 */

export type MarkupTool = "pen" | "arrow" | "rect";

export interface MarkupPoint {
  readonly x: number;
  readonly y: number;
}

export interface MarkupShape {
  readonly tool: MarkupTool;
  readonly color: string;
  /** Pen: every sampled point. Arrow and rect: [start, end]. */
  readonly points: ReadonlyArray<MarkupPoint>;
}

export const MARKUP_COLORS: ReadonlyArray<{ readonly name: string; readonly value: string }> = [
  { name: "Red", value: "#ff3b30" },
  { name: "Yellow", value: "#ffcc00" },
  { name: "Green", value: "#34c759" },
  { name: "Blue", value: "#0a84ff" },
  { name: "White", value: "#ffffff" },
  { name: "Black", value: "#000000" },
];

/** A stroke that reads the same on a 400 px thumbnail and a 4 k screenshot:
    about 0.6 % of the shorter side, never under 3 px. */
export function strokeWidthFor(width: number, height: number): number {
  return Math.max(3, Math.round(Math.min(width, height) * 0.006));
}

/** Maps a pointer position inside the canvas's on-screen box to image pixels. */
export function canvasPoint(
  box: {
    readonly left: number;
    readonly top: number;
    readonly width: number;
    readonly height: number;
  },
  canvas: { readonly width: number; readonly height: number },
  clientX: number,
  clientY: number,
): MarkupPoint {
  if (box.width <= 0 || box.height <= 0) return { x: 0, y: 0 };
  const x = ((clientX - box.left) / box.width) * canvas.width;
  const y = ((clientY - box.top) / box.height) * canvas.height;
  return {
    x: Math.min(canvas.width, Math.max(0, x)),
    y: Math.min(canvas.height, Math.max(0, y)),
  };
}

/** The two barb tips of an arrow head ending at `to`. */
export function arrowHead(
  from: MarkupPoint,
  to: MarkupPoint,
  size: number,
): readonly [MarkupPoint, MarkupPoint] {
  const angle = Math.atan2(to.y - from.y, to.x - from.x);
  const spread = Math.PI / 7;
  return [
    { x: to.x - size * Math.cos(angle - spread), y: to.y - size * Math.sin(angle - spread) },
    { x: to.x - size * Math.cos(angle + spread), y: to.y - size * Math.sin(angle + spread) },
  ];
}

/** Extends the shape being drawn with the pointer's next position. */
export function extendShape(shape: MarkupShape, point: MarkupPoint): MarkupShape {
  if (shape.tool === "pen") return { ...shape, points: [...shape.points, point] };
  const start = shape.points[0] ?? point;
  return { ...shape, points: [start, point] };
}

/** A shape too small to see is a slipped click, not a mark. */
export function isVisibleShape(shape: MarkupShape, strokeWidth: number): boolean {
  if (shape.tool === "pen") return shape.points.length > 1;
  const [a, b] = shape.points;
  if (!a || !b) return false;
  return Math.hypot(b.x - a.x, b.y - a.y) >= strokeWidth;
}

interface StrokeContext {
  beginPath(): void;
  moveTo(x: number, y: number): void;
  lineTo(x: number, y: number): void;
  stroke(): void;
  strokeRect(x: number, y: number, w: number, h: number): void;
  strokeStyle: string | CanvasGradient | CanvasPattern;
  lineWidth: number;
  lineCap: CanvasLineCap;
  lineJoin: CanvasLineJoin;
}

/** Draws every shape over whatever the context already holds. */
export function drawShapes(
  ctx: StrokeContext,
  shapes: ReadonlyArray<MarkupShape>,
  strokeWidth: number,
): void {
  ctx.lineWidth = strokeWidth;
  ctx.lineCap = "round";
  ctx.lineJoin = "round";
  for (const shape of shapes) {
    ctx.strokeStyle = shape.color;
    const [first] = shape.points;
    if (!first) continue;
    if (shape.tool === "pen") {
      ctx.beginPath();
      ctx.moveTo(first.x, first.y);
      for (const point of shape.points.slice(1)) ctx.lineTo(point.x, point.y);
      ctx.stroke();
      continue;
    }
    const last = shape.points[shape.points.length - 1] ?? first;
    if (shape.tool === "rect") {
      ctx.strokeRect(
        Math.min(first.x, last.x),
        Math.min(first.y, last.y),
        Math.abs(last.x - first.x),
        Math.abs(last.y - first.y),
      );
      continue;
    }
    ctx.beginPath();
    ctx.moveTo(first.x, first.y);
    ctx.lineTo(last.x, last.y);
    ctx.stroke();
    const [left, right] = arrowHead(first, last, strokeWidth * 4);
    ctx.beginPath();
    ctx.moveTo(left.x, left.y);
    ctx.lineTo(last.x, last.y);
    ctx.lineTo(right.x, right.y);
    ctx.stroke();
  }
}

/** The edited copy's file name: `shot.png` → `shot-marked.png`, always PNG. */
export function markedFileName(name: string): string {
  const stem = name.replace(/\.[^.]+$/, "") || "image";
  return `${stem}-marked.png`;
}
