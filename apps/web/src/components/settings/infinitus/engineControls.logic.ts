import type {
  InfinitusEngineControlInput,
  InfinitusEngineSettingsInput,
  InfinitusEngineSupervision,
  InfinitusEngines,
} from "@infinitus/contracts/infinitus";

/**
 * The pure half of the Engines page's process controls: the bridge this shell
 * offers, and what one engine's supervision reads as.
 *
 * The controls run engines on THIS machine, so they belong to the desktop
 * shell rather than the app's control socket — the placement ruled for #1213
 * and again here. A browser, the phone and an older shell have no bridge and
 * therefore no controls.
 */

export interface InfinitusEngineBridge {
  readonly getInfinitusEngines: () => Promise<InfinitusEngines>;
  readonly setInfinitusEngineSettings: (
    input: InfinitusEngineSettingsInput,
  ) => Promise<InfinitusEngines>;
  readonly controlInfinitusEngine: (
    input: InfinitusEngineControlInput,
  ) => Promise<InfinitusEngines>;
}

/** All three or nothing: a shell with only some of them is one mid-upgrade,
    and half a control panel is worse than none. */
export function infinitusEngineBridge(
  bridge: Partial<InfinitusEngineBridge> | undefined,
): InfinitusEngineBridge | null {
  if (bridge?.getInfinitusEngines === undefined) return null;
  if (bridge.setInfinitusEngineSettings === undefined) return null;
  if (bridge.controlInfinitusEngine === undefined) return null;
  return {
    getInfinitusEngines: bridge.getInfinitusEngines,
    setInfinitusEngineSettings: bridge.setInfinitusEngineSettings,
    controlInfinitusEngine: bridge.controlInfinitusEngine,
  };
}

/** The sentence under the row: what is happening, in the page's own words. */
export function engineStateLine(engine: InfinitusEngineSupervision): string {
  if (engine.mode === "service") {
    return "Started by Homebrew, which keeps it running. Stop it there to run it from here instead.";
  }
  if (engine.mode === "unknown") {
    return "Not found on this machine. Type the command that starts it to run it from here.";
  }
  switch (engine.state) {
    case "running":
      return engine.pid === null ? "Running." : `Running (pid ${engine.pid}).`;
    case "starting":
      return "Starting…";
    case "backing-off":
      return engine.error === null
        ? "Stopped unexpectedly; trying again shortly."
        : `${engine.error} Trying again shortly.`;
    case "failed":
      return engine.error ?? "The engine could not be started.";
    case "stopped":
      return engine.managed ? "Not running." : "Not running. Nothing starts it for you.";
  }
}

/** Whether the buttons do anything for this engine. Only an engine this shell
    can run has controls; a service-managed one is someone else's. */
export function engineControlsEnabled(engine: InfinitusEngineSupervision): boolean {
  return engine.mode === "child";
}

export function engineIsUp(engine: InfinitusEngineSupervision): boolean {
  return engine.state === "running" || engine.state === "starting";
}

/** The status word beside the engine's name. */
export function engineBadge(engine: InfinitusEngineSupervision): {
  readonly label: string;
  readonly tone: "up" | "down" | "warn";
} {
  if (engine.mode === "service") return { label: "Homebrew", tone: "up" };
  if (engine.mode === "unknown") return { label: "Not found", tone: "down" };
  switch (engine.state) {
    case "running":
      return { label: "Running", tone: "up" };
    case "starting":
      return { label: "Starting", tone: "warn" };
    case "backing-off":
      return { label: "Restarting", tone: "warn" };
    case "failed":
      return { label: "Failed", tone: "down" };
    case "stopped":
      return { label: "Stopped", tone: "down" };
  }
}

/**
 * The engine's own `unreachable` error, reworded when this shell knows the
 * process is simply not running. The raw sentence ("engine unreachable: Could
 * not connect to the server") is true but says nothing about what to do.
 */
export function engineErrorLine(
  engineError: string | null,
  supervision: InfinitusEngineSupervision | null,
  label: string,
): string | null {
  if (engineError === null) return null;
  if (supervision === null) return engineError;
  if (!engineError.toLowerCase().includes("unreachable")) return engineError;
  if (engineIsUp(supervision)) return engineError;
  return `${label} is not running.`;
}
