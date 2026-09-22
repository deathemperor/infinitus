import type { ModelCapabilities, ServerProviderModel } from "@infinitus/contracts";
import { createModelCapabilities } from "@infinitus/shared/model";

const EMPTY_CAPABILITIES: ModelCapabilities = createModelCapabilities({ optionDescriptors: [] });

/**
 * A row of `pi --list-models`.
 *
 * Pi prints a fixed-width table rather than JSON — there is no `--json` on this
 * subcommand — so the header names the columns and every later line is one
 * model. Nothing before the header is a row: signed out, Pi exits 0 and
 * prints only "No models available. Use /login …". Only `provider` and `model` are read; the remaining columns
 * (`context`, `max-out`, `thinking`, `images`) are display detail T3 gets from
 * the session instead.
 *
 * The parse is deliberately lenient: an unrecognised or short line is dropped
 * rather than throwing, so a future column change costs models, not the probe.
 */
export interface PiModelsCliOutput {
  readonly authenticated: boolean;
  readonly models: ReadonlyArray<ServerProviderModel>;
}

const HEADER_PREFIX = "provider";

export function parsePiModelsCliOutput(output: string): PiModelsCliOutput {
  const lines = output
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0);

  const models: ServerProviderModel[] = [];
  const seen = new Set<string>();
  let headerSeen = false;
  for (const line of lines) {
    if (line.toLowerCase().startsWith(HEADER_PREFIX)) {
      headerSeen = true;
      continue;
    }
    if (!headerSeen) continue;
    const columns = line.split(/\s+/);
    if (columns.length < 2) continue;
    const [provider, model] = columns;
    if (!provider || !model) continue;
    const slug = `${provider}/${model}`;
    if (seen.has(slug)) continue;
    seen.add(slug);
    models.push({
      slug,
      name: slug,
      isCustom: false,
      capabilities: EMPTY_CAPABILITIES,
    });
  }

  // Pi lists a model only once its provider has usable auth, so a non-empty
  // table is the authentication signal. There is no separate auth probe.
  return { authenticated: models.length > 0, models };
}
