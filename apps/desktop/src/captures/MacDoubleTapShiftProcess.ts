// @effect-diagnostics nodeBuiltinImport:off -- This macOS platform boundary spawns the native Shift poller with Node.

import * as NodeChildProcess from "node:child_process";

/**
 * The capture gesture's trigger on macOS (#433 slice 2): Shift tapped twice.
 * A sibling of the SnapShot modifier-pair poller — the same `osascript`
 * child sampling `CGEventSourceFlagsState` at 30 Hz, the same stderr
 * protocol (`ready`, then one `trigger` per gesture) — with a stricter
 * read of the samples: two presses each shorter than the window, the
 * second within the window of the first release, and no character typed
 * between them (`CGEventSourceCounterForEventType` for key-downs; modifier
 * presses are flags-changed events, so they do not count). Both Shifts held
 * at once — SnapShot's own `shift` pair — has no release, so never fires.
 */

/** Both Shift keys' device flags in `CGEventSourceFlagsState`. */
const SHIFT_DEVICE_MASK = 0x2 | 0x4;
/** A tap is a press shorter than this; the second lands this soon after the first release. */
const TAP_WINDOW_MS = 350;
/** `kCGEventKeyDown`. */
const KEY_DOWN_EVENT_TYPE = 10;

const POLLER_SCRIPT = `
ObjC.import("CoreGraphics");
ObjC.import("unistd");
function run(argv) {
  const mask = Number(argv[0]);
  const windowMs = Number(argv[1]);
  const keyDownType = Number(argv[2]);
  let down = false;
  let armed = false;
  let pressedAt = 0;
  let releasedAt = 0;
  let keyDownsAtTap = 0;
  console.log("ready");
  while ($.getppid() !== 1) {
    const now = Date.now();
    const pressed = ($.CGEventSourceFlagsState(0) & mask) !== 0;
    const keyDowns = $.CGEventSourceCounterForEventType(0, keyDownType);
    if (pressed && !down) {
      if (armed && now - releasedAt <= windowMs && keyDowns === keyDownsAtTap) {
        console.log("trigger");
        armed = false;
      } else {
        armed = true;
        keyDownsAtTap = keyDowns;
      }
      pressedAt = now;
    } else if (!pressed && down) {
      if (now - pressedAt > windowMs) armed = false;
      releasedAt = now;
    } else if (armed && !pressed && now - releasedAt > windowMs) {
      armed = false;
    }
    down = pressed;
    delay(0.03);
  }
  return "orphaned";
}`;

export function startMacDoubleTapShiftProcess(
  onTrigger: () => void,
  onFailure: (error: Error) => void,
): Promise<() => void> {
  const poller = NodeChildProcess.spawn(
    "/usr/bin/osascript",
    [
      "-l",
      "JavaScript",
      "-e",
      POLLER_SCRIPT,
      String(SHIFT_DEVICE_MASK),
      String(TAP_WINDOW_MS),
      String(KEY_DOWN_EVENT_TYPE),
    ],
    { stdio: ["ignore", "ignore", "pipe"] },
  );

  return new Promise((resolve, reject) => {
    let settled = false;
    let stopped = false;
    let buffered = "";
    const stop = () => {
      if (stopped) return;
      stopped = true;
      poller.kill();
    };
    const fail = (error: Error) => {
      if (stopped) return;
      if (settled) {
        stop();
        onFailure(error);
        return;
      }
      settled = true;
      stop();
      reject(error);
    };

    poller.stderr.on("data", (chunk: Buffer) => {
      buffered += chunk.toString();
      const lines = buffered.split("\n");
      buffered = lines.pop() ?? "";
      for (const line of lines) {
        const message = line.trim();
        if (message === "ready" && !settled) {
          settled = true;
          resolve(stop);
          continue;
        }
        if (message !== "trigger" || !settled || stopped) continue;
        try {
          onTrigger();
        } catch {}
      }
    });
    poller.once("error", (error) => {
      fail(error);
    });
    poller.once("exit", (code) => {
      fail(new Error(`Capture gesture helper exited with code ${code}`));
    });
  });
}
