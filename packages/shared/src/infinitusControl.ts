/**
 * Mirrors `ControlProtocol.socketURL()` in the native Infinitus app: the same
 * rule has to hold on both ends or the fork talks to nothing. Pure, so the
 * caller supplies the platform, environment and home directory.
 *
 * Returns null on platforms Infinitus does not run on (Windows today).
 */
export function resolveInfinitusControlSocketPath(input: {
  readonly platform: NodeJS.Platform;
  readonly env: Record<string, string | undefined>;
  readonly homeDir: string;
}): string | null {
  const override = input.env.INFINITUS_CONTROL_SOCKET;
  if (override !== undefined && override !== "") {
    return override;
  }

  if (input.platform === "darwin") {
    return `${input.homeDir}/Library/Application Support/Infinitus/control/control.sock`;
  }

  if (input.platform === "linux") {
    // The runtime dir is where a per-user socket belongs (tmpfs, 0700, cleared
    // at logout); without one the state dir is the stable stand-in.
    const runtimeDir = input.env.XDG_RUNTIME_DIR;
    if (runtimeDir !== undefined && runtimeDir !== "") {
      return `${runtimeDir}/infinitus/control.sock`;
    }
    return `${input.homeDir}/.local/state/infinitus/control.sock`;
  }

  return null;
}
