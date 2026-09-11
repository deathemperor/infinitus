import type { ServerConfig } from "@t3tools/contracts";
import * as Option from "effect/Option";

import type { BearerConnectionProfile, ConnectionCatalogEntry } from "./catalog.ts";
import type { SupervisorConnectionState } from "./model.ts";

export type EnvironmentConnectionPhase =
  | "available"
  | "offline"
  | "connecting"
  | "reconnecting"
  | "connected"
  | "error";

export interface EnvironmentConnectionPresentation {
  readonly phase: EnvironmentConnectionPhase;
  readonly error: string | null;
  readonly traceId: string | null;
}

export interface EnvironmentPresentation {
  readonly entry: ConnectionCatalogEntry;
  readonly connection: EnvironmentConnectionPresentation;
  readonly serverConfig: ServerConfig | null;
}

export function presentConnectionState(
  state: SupervisorConnectionState,
): EnvironmentConnectionPresentation {
  switch (state.phase) {
    case "available":
      return { phase: "available", error: null, traceId: null };
    case "offline":
      return { phase: "offline", error: null, traceId: null };
    case "connecting":
      return {
        phase: state.attempt <= 1 && state.lastFailure === null ? "connecting" : "reconnecting",
        error: state.lastFailure?.message ?? null,
        traceId: state.lastFailure?.traceId ?? null,
      };
    case "connected":
      return { phase: "connected", error: null, traceId: null };
    case "backoff":
      return {
        phase: "reconnecting",
        error: state.lastFailure?.message ?? null,
        traceId: state.lastFailure?.traceId ?? null,
      };
    case "blocked":
      return {
        phase: "error",
        error: state.lastFailure?.message ?? null,
        traceId: state.lastFailure?.traceId ?? null,
      };
  }
}

export function connectionStatusText(connection: EnvironmentConnectionPresentation): string {
  switch (connection.phase) {
    case "available":
      return "Available";
    case "offline":
      return "Offline";
    case "connecting":
      return "Connecting...";
    case "reconnecting":
      return connection.error
        ? `Failed to connect. Reconnecting... Reason: ${connection.error}`
        : "Reconnecting...";
    case "connected":
      return "Connected";
    case "error":
      return connection.error
        ? `Connection failed. Reason: ${connection.error}`
        : "Connection failed";
  }
}

export function connectionStatusTitle(connection: EnvironmentConnectionPresentation): string {
  if (connection.phase === "reconnecting" && connection.error) {
    return "Failed to connect. Reconnecting...";
  }
  return connectionStatusText({ ...connection, error: null });
}

export function presentEnvironmentConnection(
  state: SupervisorConnectionState,
): EnvironmentConnectionPresentation {
  return presentConnectionState(state);
}

export function connectionCatalogDisplayUrl(entry: ConnectionCatalogEntry): string | null {
  switch (entry.target._tag) {
    case "PrimaryConnectionTarget":
      return entry.target.httpBaseUrl;
    case "RelayConnectionTarget":
      return null;
    case "BearerConnectionTarget":
      return Option.isSome(entry.profile) && entry.profile.value._tag === "BearerConnectionProfile"
        ? entry.profile.value.httpBaseUrl
        : null;
    case "SshConnectionTarget":
      return Option.isSome(entry.profile) && entry.profile.value._tag === "SshConnectionProfile"
        ? `${entry.profile.value.target.username}@${entry.profile.value.target.hostname}`
        : null;
  }
}

/** Fork (#663): the bearer profile behind an entry, when it has one. */
function bearerProfileOf(entry: ConnectionCatalogEntry): BearerConnectionProfile | null {
  if (
    entry.target._tag !== "BearerConnectionTarget" ||
    Option.isNone(entry.profile) ||
    entry.profile.value._tag !== "BearerConnectionProfile"
  ) {
    return null;
  }
  return entry.profile.value;
}

/** Fork (#663): the environment's other hosts — the tunnel it also answers
    on — with the paired host left out; what a row names as reachable away. */
export function connectionCatalogAlternateHosts(
  entry: ConnectionCatalogEntry,
): ReadonlyArray<string> {
  const profile = bearerProfileOf(entry);
  if (profile === null) return [];
  return (profile.alternateHttpBaseUrls ?? []).filter(
    (host, index, all) => host !== profile.httpBaseUrl && all.indexOf(host) === index,
  );
}

/** Fork (#663): the host the last connect got through on, when it was not
    the paired one — null while the phone connects the plain way. */
export function connectionCatalogRoamedHost(entry: ConnectionCatalogEntry): string | null {
  const profile = bearerProfileOf(entry);
  if (profile === null || profile.lastGoodHttpBaseUrl === undefined) return null;
  return profile.lastGoodHttpBaseUrl === profile.httpBaseUrl ? null : profile.lastGoodHttpBaseUrl;
}
