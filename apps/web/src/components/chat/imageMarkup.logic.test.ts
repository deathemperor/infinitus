import { describe, expect, it } from "vite-plus/test";

import {
  arrowHead,
  canvasPoint,
  drawShapes,
  extendShape,
  isVisibleShape,
  markedFileName,
  strokeWidthFor,
  type MarkupShape,
} from "./imageMarkup.logic";

describe("strokeWidthFor", () => {
  it("scales with the shorter side and never drops under 3 px", () => {
    expect(strokeWidthFor(400, 300)).toBe(3);
    expect(strokeWidthFor(3000, 2000)).toBe(12);
  });
});

describe("canvasPoint", () => {
  it("maps a screen position to image pixels through the on-screen box", () => {
    const box = { left: 100, top: 50, width: 200, height: 100 };
    expect(canvasPoint(box, { width: 2000, height: 1000 }, 200, 100)).toEqual({ x: 1000, y: 500 });
  });

  it("clamps to the image", () => {
    const box = { left: 0, top: 0, width: 100, height: 100 };
    expect(canvasPoint(box, { width: 100, height: 100 }, -20, 250)).toEqual({ x: 0, y: 100 });
  });

  it("answers the origin for a box with no size", () => {
    expect(
      canvasPoint({ left: 0, top: 0, width: 0, height: 0 }, { width: 10, height: 10 }, 5, 5),
    ).toEqual({
      x: 0,
      y: 0,
    });
  });
});

describe("arrowHead", () => {
  it("puts both barbs behind the tip of a rightward arrow", () => {
    const [a, b] = arrowHead({ x: 0, y: 0 }, { x: 100, y: 0 }, 10);
    expect(a.x).toBeLessThan(100);
    expect(b.x).toBeLessThan(100);
    expect(a.y).toBeCloseTo(-b.y);
  });
});

describe("extendShape", () => {
  it("appends to a pen stroke and replaces the end of an arrow or rect", () => {
    const pen: MarkupShape = { tool: "pen", color: "#fff", points: [{ x: 0, y: 0 }] };
    expect(extendShape(pen, { x: 1, y: 1 }).points).toHaveLength(2);
    const rect: MarkupShape = {
      tool: "rect",
      color: "#fff",
      points: [
        { x: 0, y: 0 },
        { x: 5, y: 5 },
      ],
    };
    expect(extendShape(rect, { x: 9, y: 9 }).points).toEqual([
      { x: 0, y: 0 },
      { x: 9, y: 9 },
    ]);
  });
});

describe("isVisibleShape", () => {
  it("drops a slipped click", () => {
    expect(isVisibleShape({ tool: "pen", color: "#fff", points: [{ x: 0, y: 0 }] }, 3)).toBe(false);
    expect(
      isVisibleShape(
        {
          tool: "arrow",
          color: "#fff",
          points: [
            { x: 0, y: 0 },
            { x: 1, y: 1 },
          ],
        },
        3,
      ),
    ).toBe(false);
    expect(
      isVisibleShape(
        {
          tool: "arrow",
          color: "#fff",
          points: [
            { x: 0, y: 0 },
            { x: 30, y: 0 },
          ],
        },
        3,
      ),
    ).toBe(true);
  });
});

describe("drawShapes", () => {
  it("strokes a pen path, a rectangle and an arrow with its head", () => {
    const calls: string[] = [];
    const ctx = {
      beginPath: () => calls.push("begin"),
      moveTo: () => calls.push("move"),
      lineTo: () => calls.push("line"),
      stroke: () => calls.push("stroke"),
      strokeRect: () => calls.push("rect"),
      strokeStyle: "",
      lineWidth: 0,
      lineCap: "butt" as CanvasLineCap,
      lineJoin: "miter" as CanvasLineJoin,
    };
    drawShapes(
      ctx,
      [
        {
          tool: "pen",
          color: "#f00",
          points: [
            { x: 0, y: 0 },
            { x: 1, y: 1 },
            { x: 2, y: 2 },
          ],
        },
        {
          tool: "rect",
          color: "#0f0",
          points: [
            { x: 0, y: 0 },
            { x: 4, y: 4 },
          ],
        },
        {
          tool: "arrow",
          color: "#00f",
          points: [
            { x: 0, y: 0 },
            { x: 40, y: 0 },
          ],
        },
      ],
      4,
    );
    expect(calls.filter((c) => c === "rect")).toHaveLength(1);
    expect(calls.filter((c) => c === "stroke")).toHaveLength(3);
    expect(ctx.lineWidth).toBe(4);
    expect(ctx.strokeStyle).toBe("#00f");
  });
});

describe("markedFileName", () => {
  it("keeps the stem and forces png", () => {
    expect(markedFileName("shot.jpeg")).toBe("shot-marked.png");
    expect(markedFileName("image")).toBe("image-marked.png");
    expect(markedFileName(".png")).toBe("image-marked.png");
  });
});
