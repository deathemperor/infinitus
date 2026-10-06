/**
 * piHomeEnvironment — the one place Pi's config directory is decided.
 *
 * Every way we run the `pi` binary (the RPC session, the status probe, the
 * one-shot text generation) goes through this, because getting it wrong is
 * not a small bug: Oh My Pi is a fork of Pi that kept `APP_NAME = "pi"`, so
 * `omp` derives and reads this very same variable. An ambient value set for
 * Oh My Pi would silently point Pi at Oh My Pi's directory, sharing auth,
 * config and transcripts between two agents the user configured separately.
 *
 * @module provider/Layers/piHomeEnvironment
 */
import { expandHomePath } from "../../pathExpansion.ts";

/** Pi's config directory environment variable. See the module comment. */
const PI_HOME_ENV_VAR = "PI_CODING_AGENT_DIR";

/**
 * Strips an ambient `PI_CODING_AGENT_DIR` and applies the instance's
 * `homePath` when it has one.
 *
 * The expansion matters: a value handed to `spawn` is not shell-expanded, so
 * a `~`-relative setting would otherwise reach Pi as a literal `~`.
 */
export function piHomeEnvironment(
  environment: NodeJS.ProcessEnv,
  homePath: string | undefined,
): NodeJS.ProcessEnv {
  const { [PI_HOME_ENV_VAR]: _ambient, ...rest } = environment;
  const trimmed = homePath?.trim();
  return trimmed ? { ...rest, [PI_HOME_ENV_VAR]: expandHomePath(trimmed) } : rest;
}
