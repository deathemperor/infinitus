import type { AuthClientPresentationMetadata } from "@t3tools/contracts";
import { withRelayClientTracing } from "@t3tools/shared/relayTracing";
import * as Cause from "effect/Cause";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Exit from "effect/Exit";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as Schema from "effect/Schema";

import { appendClientConnectionParams } from "../authorization/remote.ts";
import * as RemoteEnvironmentAuthorization from "../authorization/service.ts";
import type { AuthorizedRemoteEnvironment } from "../authorization/service.ts";
import * as ClientCapabilities from "../platform/capabilities.ts";
import {
  BearerConnectionCredential,
  BearerConnectionProfile,
  type ConnectionCatalogEntry,
  SshConnectionProfile,
} from "./catalog.ts";
import * as ConnectionCredentialStore from "./credentialStore.ts";
import { credentialMissingError, environmentMismatchError, profileMissingError } from "./errors.ts";
import type {
  BearerConnectionTarget,
  ConnectionTarget,
  PreparedConnection,
  PrimaryConnectionTarget,
  RelayConnectionTarget,
  SshConnectionTarget,
} from "./model.ts";
import { ConnectionBlockedError, type ConnectionAttemptError } from "./model.ts";
import * as ConnectionProfileStore from "./profileStore.ts";
import {
  bearerHostOrder,
  learnedBearerProfile,
  ROAM_PROBE_TIMEOUT_MS,
  roamedWsBaseUrl,
  roamsPast,
} from "./roaming.ts";

export class ConnectionResolver extends Context.Service<
  ConnectionResolver,
  {
    readonly prepare: (
      entry: ConnectionCatalogEntry,
    ) => Effect.Effect<PreparedConnection, ConnectionAttemptError>;
  }
>()("@t3tools/client-runtime/connection/resolver/ConnectionResolver") {}

const isBearerProfile = Schema.is(BearerConnectionProfile);
const isSshProfile = Schema.is(SshConnectionProfile);
const isBearerCredential = Schema.is(BearerConnectionCredential);

function primarySocketUrl(
  target: PrimaryConnectionTarget,
  clientMetadata: AuthClientPresentationMetadata | undefined,
): string {
  const url = new URL(target.wsBaseUrl);
  if (url.pathname === "" || url.pathname === "/") {
    url.pathname = "/ws";
  }
  appendClientConnectionParams(url, clientMetadata, "direct");
  return url.toString();
}

const makePrimaryBroker = Effect.fn("clientRuntime.connection.broker.makePrimary")(function* () {
  const auth = yield* ClientCapabilities.PrimaryEnvironmentAuth;
  const presentation = yield* ClientCapabilities.ClientPresentation;
  const remote = yield* RemoteEnvironmentAuthorization.RemoteEnvironmentAuthorization;

  return Effect.fn("clientRuntime.connection.broker.primary")(function* (
    target: PrimaryConnectionTarget,
  ) {
    const bearerToken = yield* auth.bearerToken;
    if (Option.isNone(bearerToken)) {
      return {
        environmentId: target.environmentId,
        label: target.label,
        httpBaseUrl: target.httpBaseUrl,
        socketUrl: primarySocketUrl(target, presentation.metadata),
        httpAuthorization: null,
        target,
      } satisfies PreparedConnection;
    }

    const authorized = yield* remote.authorizeBearer({
      expectedEnvironmentId: target.environmentId,
      httpBaseUrl: target.httpBaseUrl,
      wsBaseUrl: target.wsBaseUrl,
      bearerToken: bearerToken.value,
      connectionMethod: "direct",
    });
    return {
      ...authorized,
      target,
    } satisfies PreparedConnection;
  });
});

const makeBearerBroker = Effect.fn("clientRuntime.connection.broker.makeBearer")(function* () {
  const credentials = yield* ConnectionCredentialStore.ConnectionCredentialStore;
  const profiles = yield* ConnectionProfileStore.ConnectionProfileStore;
  const remote = yield* RemoteEnvironmentAuthorization.RemoteEnvironmentAuthorization;

  return Effect.fn("clientRuntime.connection.broker.bearer")(function* (
    entry: ConnectionCatalogEntry & { readonly target: BearerConnectionTarget },
  ) {
    const target = entry.target;
    const profile = yield* Option.match(entry.profile, {
      onNone: () => Effect.fail(profileMissingError(target.connectionId)),
      onSome: Effect.succeed,
    });
    if (!isBearerProfile(profile)) {
      return yield* new ConnectionBlockedError({
        reason: "configuration",
        detail: `Connection profile ${target.connectionId} is not a bearer connection.`,
      });
    }
    if (profile.environmentId !== target.environmentId) {
      return yield* environmentMismatchError({
        expected: target.environmentId,
        actual: profile.environmentId,
      });
    }
    const credential = yield* credentials.get(target.connectionId).pipe(
      Effect.flatMap(
        Option.match({
          onNone: () => Effect.fail(credentialMissingError(target.connectionId)),
          onSome: Effect.succeed,
        }),
      ),
    );
    if (!isBearerCredential(credential)) {
      return yield* credentialMissingError(target.connectionId);
    }
    // Fork (#663): the paired host first (or the one that worked last), then
    // the server's alternates — its tunnel — when a host cannot be reached at
    // all. A host that answers and refuses ends the walk. Every host but the
    // last gets the short descriptor wait.
    const hosts = bearerHostOrder(profile);
    let authorized: AuthorizedRemoteEnvironment | undefined;
    for (const [index, httpBaseUrl] of hosts.entries()) {
      const last = index === hosts.length - 1;
      const attempt = yield* Effect.exit(
        remote.authorizeBearer({
          expectedEnvironmentId: target.environmentId,
          httpBaseUrl,
          wsBaseUrl:
            httpBaseUrl === profile.httpBaseUrl ? profile.wsBaseUrl : roamedWsBaseUrl(httpBaseUrl),
          bearerToken: credential.token,
          connectionMethod: "direct",
          ...(last ? {} : { descriptorTimeoutMs: ROAM_PROBE_TIMEOUT_MS }),
        }),
      );
      if (Exit.isSuccess(attempt)) {
        authorized = attempt.value;
        break;
      }
      const failure = Cause.findErrorOption(attempt.cause);
      if (last || Option.isNone(failure) || !roamsPast(failure.value)) {
        return yield* Effect.failCause(attempt.cause);
      }
    }
    if (authorized === undefined) return yield* profileMissingError(target.connectionId);
    const learned = learnedBearerProfile(profile, authorized.httpBaseUrl, authorized);
    if (learned !== null) yield* profiles.put(learned);
    return {
      environmentId: authorized.environmentId,
      label: authorized.label,
      httpBaseUrl: authorized.httpBaseUrl,
      socketUrl: authorized.socketUrl,
      httpAuthorization: authorized.httpAuthorization,
      target,
    } satisfies PreparedConnection;
  });
});

const makeRelayBroker = Effect.fn("clientRuntime.connection.broker.makeRelay")(function* () {
  const remote = yield* RemoteEnvironmentAuthorization.RemoteEnvironmentAuthorization;

  return Effect.fnUntraced(
    function* (target: RelayConnectionTarget) {
      const authorized = yield* remote.authorizeDpop({
        expectedEnvironmentId: target.environmentId,
      });
      return {
        environmentId: authorized.environmentId,
        label: authorized.label,
        httpBaseUrl: authorized.httpBaseUrl,
        socketUrl: authorized.socketUrl,
        httpAuthorization: authorized.httpAuthorization,
        target,
      } satisfies PreparedConnection;
    },
    Effect.withSpan("clientRuntime.connection.broker.relay"),
    withRelayClientTracing,
  );
});

const makeSshBroker = Effect.fn("clientRuntime.connection.broker.makeSsh")(function* () {
  const profiles = yield* ConnectionProfileStore.ConnectionProfileStore;
  const ssh = yield* ClientCapabilities.SshEnvironmentGateway;
  const remote = yield* RemoteEnvironmentAuthorization.RemoteEnvironmentAuthorization;

  return Effect.fn("clientRuntime.connection.broker.ssh")(function* (
    entry: ConnectionCatalogEntry & { readonly target: SshConnectionTarget },
  ) {
    const target = entry.target;
    const profile = yield* Option.match(entry.profile, {
      onNone: () => Effect.fail(profileMissingError(target.connectionId)),
      onSome: Effect.succeed,
    });
    if (!isSshProfile(profile)) {
      return yield* new ConnectionBlockedError({
        reason: "configuration",
        detail: `Connection profile ${target.connectionId} is not an SSH connection.`,
      });
    }
    if (profile.environmentId !== target.environmentId) {
      return yield* environmentMismatchError({
        expected: target.environmentId,
        actual: profile.environmentId,
      });
    }
    const prepared = yield* ssh.prepare({
      connectionId: target.connectionId,
      expectedEnvironmentId: target.environmentId,
      target: profile.target,
    });
    yield* profiles.put(
      new SshConnectionProfile({
        connectionId: profile.connectionId,
        environmentId: profile.environmentId,
        label: profile.label,
        target: prepared.bootstrap.target,
      }),
    );
    const authorized = yield* remote.authorizeBearer({
      expectedEnvironmentId: target.environmentId,
      httpBaseUrl: prepared.bootstrap.httpBaseUrl,
      wsBaseUrl: prepared.bootstrap.wsBaseUrl,
      bearerToken: prepared.bearerToken,
      connectionMethod: "ssh",
    });
    return {
      environmentId: authorized.environmentId,
      label: authorized.label,
      httpBaseUrl: authorized.httpBaseUrl,
      socketUrl: authorized.socketUrl,
      httpAuthorization: authorized.httpAuthorization,
      target,
    } satisfies PreparedConnection;
  });
});

/** @public Service construction is part of the canonical Effect module API. */
export const make = Effect.gen(function* () {
  const primary = yield* makePrimaryBroker();
  const bearer = yield* makeBearerBroker();
  const relay = yield* makeRelayBroker();
  const ssh = yield* makeSshBroker();

  const prepare = Effect.fn("clientRuntime.connection.broker.prepare")(function* (
    entry: ConnectionCatalogEntry,
  ) {
    const target: ConnectionTarget = entry.target;
    yield* Effect.annotateCurrentSpan({
      "connection.environment.id": target.environmentId,
      "connection.target.kind": target._tag,
    });
    switch (target._tag) {
      case "PrimaryConnectionTarget":
        return yield* primary(target);
      case "BearerConnectionTarget":
        return yield* bearer({ ...entry, target });
      case "RelayConnectionTarget":
        return yield* relay(target);
      case "SshConnectionTarget":
        return yield* ssh({ ...entry, target });
    }
  });

  return ConnectionResolver.of({ prepare });
});

export const layer = Layer.effect(ConnectionResolver, make);
