import {
  connectionCatalogAlternateHosts,
  connectionCatalogRoamedHost,
  type ConnectionCatalogEntry,
} from "@infinitus/client-runtime/connection";

/**
 * Fork (#663): the line under a saved environment's host. While the phone is
 * connected through the environment's other door (its tunnel) it says so;
 * otherwise it names the doors it tries ahead of the paired host. Nothing for
 * an environment with one host.
 */
export function roamingHostsLine(entry: ConnectionCatalogEntry | null): string | null {
  if (entry === null) return null;
  const roamed = connectionCatalogRoamedHost(entry);
  if (roamed !== null) return `Connected via ${roamed}`;
  const alternates = connectionCatalogAlternateHosts(entry);
  return alternates.length === 0 ? null : `Tries ${alternates.join(", ")} first`;
}
