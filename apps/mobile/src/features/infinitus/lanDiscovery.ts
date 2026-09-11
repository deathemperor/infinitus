import {
  type NearbyServer,
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
  return response.json();
};

/**
 * Sweeps the phone's /24 for Infinitus servers, reporting each as it answers.
 * Resolves when every address has been tried or `signal` aborts. Never throws:
 * a dead address is the normal case.
 */
export async function discoverNearbyServers(input: {
  readonly ownIp: string | null;
  readonly signal: AbortSignal;
  readonly onFound: (server: NearbyServer) => void;
  readonly probe?: Probe;
}): Promise<void> {
  const probe = input.probe ?? fetchProbe;
  const queue = [...subnetCandidates(input.ownIp)];
  const worker = async () => {
    while (queue.length > 0 && !input.signal.aborted) {
      const ip = queue.shift()!;
      const server = await probeOne(ip, input.signal, probe);
      if (server !== null && !input.signal.aborted) input.onFound(server);
    }
  };
  await Promise.all(Array.from({ length: CONCURRENCY }, worker));
}

async function probeOne(
  ip: string,
  parent: AbortSignal,
  probe: Probe,
): Promise<NearbyServer | null> {
  const controller = new AbortController();
  const abort = () => controller.abort();
  parent.addEventListener("abort", abort);
  const timer = setTimeout(abort, PROBE_TIMEOUT_MS);
  try {
    return nearbyServerFromDescriptor(ip, await probe(probeUrl(ip), controller.signal));
  } catch {
    return null;
  } finally {
    clearTimeout(timer);
    parent.removeEventListener("abort", abort);
  }
}
