import { ArrowUpRightIcon, PenLineIcon, SquareIcon, Undo2Icon } from "lucide-react";
import { useCallback, useEffect, useRef, useState } from "react";

import { cn } from "~/lib/utils";
import { Button } from "../ui/button";
import {
  Dialog,
  DialogFooter,
  DialogHeader,
  DialogPanel,
  DialogPopup,
  DialogTitle,
} from "../ui/dialog";
import { Toggle, ToggleGroup } from "../ui/toggle-group";
import {
  MARKUP_COLORS,
  canvasPoint,
  drawShapes,
  extendShape,
  isVisibleShape,
  strokeWidthFor,
  type MarkupShape,
  type MarkupTool,
} from "./imageMarkup.logic";

interface ImageMarkupDialogProps {
  readonly open: boolean;
  readonly imageName: string;
  readonly previewUrl: string;
  readonly onCancel: () => void;
  /** The edited image as PNG; the caller swaps the attachment. */
  readonly onSave: (blob: Blob) => void;
}

/**
 * Fork (#875): draw on a draft image before sending — pen, arrow, rectangle,
 * six colours, undo. The canvas holds the image at its natural size and the
 * strokes on top; Save exports a PNG and the composer replaces the attachment
 * under a new id (so it re-uploads), Cancel keeps the original untouched.
 */
export function ImageMarkupDialog(props: ImageMarkupDialogProps) {
  const canvasRef = useRef<HTMLCanvasElement | null>(null);
  const imageRef = useRef<HTMLImageElement | null>(null);
  const [ready, setReady] = useState(false);
  const [failed, setFailed] = useState(false);
  const [tool, setTool] = useState<MarkupTool>("pen");
  const [color, setColor] = useState(MARKUP_COLORS[0]!.value);
  const [shapes, setShapes] = useState<ReadonlyArray<MarkupShape>>([]);
  const [drawing, setDrawing] = useState<MarkupShape | null>(null);
  const [saving, setSaving] = useState(false);

  // The composer mounts this dialog per image and only while it is open, so
  // every state above starts fresh; the effect only loads the pixels.
  useEffect(() => {
    if (!props.open) return;
    const image = new Image();
    const controller = new AbortController();
    image.addEventListener(
      "load",
      () => {
        imageRef.current = image;
        setReady(true);
      },
      { once: true, signal: controller.signal },
    );
    image.addEventListener("error", () => setFailed(true), {
      once: true,
      signal: controller.signal,
    });
    image.src = props.previewUrl;
    return () => {
      controller.abort();
      imageRef.current = null;
    };
  }, [props.open, props.previewUrl]);

  const paint = useCallback(() => {
    const canvas = canvasRef.current;
    const image = imageRef.current;
    if (!canvas || !image) return;
    if (canvas.width !== image.naturalWidth || canvas.height !== image.naturalHeight) {
      canvas.width = image.naturalWidth;
      canvas.height = image.naturalHeight;
    }
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    ctx.drawImage(image, 0, 0);
    drawShapes(
      ctx,
      drawing ? [...shapes, drawing] : shapes,
      strokeWidthFor(canvas.width, canvas.height),
    );
  }, [drawing, shapes]);

  useEffect(() => {
    if (ready) paint();
  }, [paint, ready]);

  const pointAt = (event: React.PointerEvent<HTMLCanvasElement>) => {
    const canvas = event.currentTarget;
    return canvasPoint(canvas.getBoundingClientRect(), canvas, event.clientX, event.clientY);
  };

  const onPointerDown = (event: React.PointerEvent<HTMLCanvasElement>) => {
    if (!ready || event.button !== 0) return;
    event.currentTarget.setPointerCapture(event.pointerId);
    setDrawing({ tool, color, points: [pointAt(event)] });
  };
  const onPointerMove = (event: React.PointerEvent<HTMLCanvasElement>) => {
    if (!drawing) return;
    setDrawing(extendShape(drawing, pointAt(event)));
  };
  const finishStroke = () => {
    if (!drawing) return;
    const canvas = canvasRef.current;
    const strokeWidth = canvas ? strokeWidthFor(canvas.width, canvas.height) : 3;
    if (isVisibleShape(drawing, strokeWidth)) setShapes((previous) => [...previous, drawing]);
    setDrawing(null);
  };

  const save = () => {
    const canvas = canvasRef.current;
    if (!canvas || saving) return;
    setSaving(true);
    canvas.toBlob((blob) => {
      setSaving(false);
      if (blob) props.onSave(blob);
      else setFailed(true);
    }, "image/png");
  };

  return (
    <Dialog open={props.open} onOpenChange={(open) => (open ? undefined : props.onCancel())}>
      <DialogPopup className="w-full sm:max-w-[min(92vw,72rem)]">
        <DialogHeader>
          <DialogTitle>Draw on {props.imageName}</DialogTitle>
        </DialogHeader>
        <DialogPanel className="flex min-h-0 flex-col gap-3">
          <div className="flex flex-wrap items-center gap-3">
            <ToggleGroup
              value={[tool]}
              onValueChange={(value) => {
                const next = value[0];
                if (next === "pen" || next === "arrow" || next === "rect") setTool(next);
              }}
              aria-label="Drawing tool"
            >
              <Toggle value="pen" aria-label="Pen">
                <PenLineIcon />
              </Toggle>
              <Toggle value="arrow" aria-label="Arrow">
                <ArrowUpRightIcon />
              </Toggle>
              <Toggle value="rect" aria-label="Rectangle">
                <SquareIcon />
              </Toggle>
            </ToggleGroup>
            <div className="flex items-center gap-1.5" role="radiogroup" aria-label="Colour">
              {MARKUP_COLORS.map((option) => (
                <button
                  key={option.value}
                  type="button"
                  role="radio"
                  aria-checked={color === option.value}
                  aria-label={option.name}
                  onClick={() => setColor(option.value)}
                  className={cn(
                    "size-5 rounded-full border border-border shadow-xs",
                    color === option.value &&
                      "ring-2 ring-ring ring-offset-2 ring-offset-background",
                  )}
                  style={{ backgroundColor: option.value }}
                />
              ))}
            </div>
            <Button
              variant="ghost"
              size="sm"
              disabled={shapes.length === 0}
              onClick={() => setShapes((previous) => previous.slice(0, -1))}
              aria-label="Undo"
            >
              <Undo2Icon />
              Undo
            </Button>
          </div>
          <div className="flex min-h-0 flex-1 items-center justify-center overflow-hidden rounded-md bg-muted/40">
            {failed ? (
              <p className="p-6 text-muted-foreground text-sm">This image could not be loaded.</p>
            ) : (
              <canvas
                ref={canvasRef}
                className={cn(
                  "max-h-[70vh] max-w-full touch-none select-none",
                  ready ? "cursor-crosshair" : "opacity-0",
                )}
                onPointerDown={onPointerDown}
                onPointerMove={onPointerMove}
                onPointerUp={finishStroke}
                onPointerCancel={finishStroke}
                aria-label={`Drawing surface for ${props.imageName}`}
              />
            )}
          </div>
        </DialogPanel>
        <DialogFooter>
          <Button variant="ghost" onClick={props.onCancel}>
            Cancel
          </Button>
          <Button disabled={!ready || failed || shapes.length === 0 || saving} onClick={save}>
            Save copy
          </Button>
        </DialogFooter>
      </DialogPopup>
    </Dialog>
  );
}
