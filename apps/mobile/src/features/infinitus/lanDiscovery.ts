import {
  INFINITUS_SERVER_PORT,
  type NearbyServer,
  type SweepReport,
  nearbyServerFromDescriptor,
  probeUrl,
  subnetCandidates,
} from "./lanDiscovery.logic";

const CONCURRENCY = 24;
const PROBE_TIMEOUT_MS = 800;

/** One address: the descriptor's JSON, or null for a refusal, a timeout, a
    non-JSON answer — anything that is not a server worth listing. */
export type Probe = (url: string, signal: AbortSignal) => Promise<unknown>;

export const fetchProbe: Probe = async (url, signal) => {
  const response = await fetch(url, { signal, headers: { accept: "application/json" } });
  if (!response.ok) return null;
  return response.json().catch(() => null);
};

type Outcome =
  | { readonly kind: "server"; readonly server: NearbyServer }
  | { readonly kind: "other" }
  | { readonly kind: "timeout" }
  | { readonly kind: "failed"; readonly message: string }
  | { readonly kind: "aborted" };

/**
 * Sweeps the phone's /24 for Infinitus servers, reporting each as it answers.
 * Resolves with the sweep's report (#787) when every address has been tried
 * or `signal` aborts. Never throws: a dead address is the normal case.
 */
export async function discoverNearbyServers(input: {
  readonly ownIp: string | null;
  readonly network?: string | null;
  readonly signal: AbortSignal;
  readonly onFound: (server: NearbyServer) => void;
  readonly probe?: Probe;
  readonly now?: () => number;
  /** Tests only: the per-address cut-off. */
  readonly timeoutMs?: number;
}): Promise<SweepReport> {
  const probe = input.probe ?? fetchProbe;
  const now = input.now ?? Date.now;
  const timeoutMs = input.timeoutMs ?? PROBE_TIMEOUT_MS;
  const started = now();
  const queue = [...subnetCandidates(input.ownIp)];
  const counts = { probed: 0, servers: 0, answeredOther: 0, timedOut: 0, failed: 0 };
  let failure: string | null = null;
  const worker = async () => {
    while (queue.length > 0 && !input.signal.aborted) {
      const ip = queue.shift()!;
      counts.probed += 1;
      const outcome = await probeOne(ip, input.signal, probe, timeoutMs);
      switch (outcome.kind) {
        case "server":
          counts.servers += 1;
          if (!input.signal.aborted) input.onFound(outcome.server);
          break;
        case "other":
          counts.answeredOther += 1;
          break;
        case "timeout":
          counts.timedOut += 1;
          break;
        case "failed":
          counts.failed += 1;
          failure ??= outcome.message;
          break;
        case "aborted":
          break;
      }
    }
  };
  await Promise.all(Array.from({ length: CONCURRENCY }, worker));
  return {
    ownIp: input.ownIp,
    network: input.network ?? null,
    port: INFINITUS_SERVER_PORT,
    timeoutMs,
    ...counts,
    failure,
    aborted: input.signal.aborted,
    elapsedMs: now() - started,
  };
}

async function probeOne(
  ip: string,
  parent: AbortSignal,
  probe: Probe,
  timeoutMs: number,
): Promise<Outcome> {
  const controller = new AbortController();
  const abort = () => controller.abort();
  parent.addEventListener("abort", abort);
  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    controller.abort();
  }, timeoutMs);
  try {
    const server = nearbyServerFromDescriptor(ip, await probe(probeUrl(ip), controller.signal));
    return server === null ? { kind: "other" } : { kind: "server", server };
  } catch (error) {
    if (parent.aborted) return { kind: "aborted" };
    if (timedOut) return { kind: "timeout" };
    return { kind: "failed", message: failureMessage(error) };
  } finally {
    clearTimeout(timer);
    parent.removeEventListener("abort", abort);
  }
}

/** The transport's words, one line, capped: no body, no address. */
function failureMessage(error: unknown): string {
  const raw = error instanceof Error ? error.message : String(error);
  const line = raw.split("\n")[0]?.trim() ?? "";
  return line.length > 80 ? `${line.slice(0, 79)}…` : line.length === 0 ? "unknown error" : line;
}
