import {
  connectionCatalogAlternateHosts,
  connectionCatalogRoamedHost,
  type ConnectionCatalogEntry,
} from "@t3tools/client-runtime/connection";

/**
 * Fork (#663): the line under a saved environment's host. While the phone is
 * connected through the environment's other door (its tunnel) it says so;
 * otherwise it names the doors it could roam to. Nothing for an environment
 * with one host.
 */
export function roamingHostsLine(entry: ConnectionCatalogEntry | null): string | null {
  if (entry === null) return null;
  const roamed = connectionCatalogRoamedHost(entry);
  if (roamed !== null) return `Connected via ${roamed}`;
  const alternates = connectionCatalogAlternateHosts(entry);
  return alternates.length === 0 ? null : `Also via ${alternates.join(", ")} when you are away`;
}
