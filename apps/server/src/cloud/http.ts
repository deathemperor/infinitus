import {
  AuthRelayReadScope,
  AuthRelayWriteScope,
  EnvironmentCloudEndpointUnavailableError,
  EnvironmentHttpApi,
  EnvironmentHttpBadRequestError,
  EnvironmentHttpConflictError,
  EnvironmentHttpForbiddenError,
  EnvironmentHttpInternalServerError,
  EnvironmentHttpUnauthorizedError,
} from "@infinitus/contracts";
import * as Effect from "effect/Effect";
import * as HttpEffect from "effect/http/HttpEffect";
import { HttpServerRequest, HttpServerResponse } from "effect/http";
import * as HttpApiBuilder from "effect/http-api/HttpApiBuilder";

import { requireEnvironmentScope } from "../auth/http.ts";
import * as EnvironmentAuth from "../auth/EnvironmentAuth.ts";
import * as CloudLink from "./CloudLink.ts";
import type { RelayRequestError } from "./relayResponse.ts";
import { traceRelayRequest } from "./traceRelayRequest.ts";
<<<<<<< HEAD
import { filterRelayResponse, relayRequestError, shouldRetryCloudLink } from "./relayResponse.ts";
import { CONNECT_NAME } from "@infinitus/shared/productName";
=======
>>>>>>> upstream-sync-cd41c4ada-upstream-renamed

const CLOUD_CREDENTIAL_RESPONSE_HEADERS = {
  "cache-control": "no-store",
  pragma: "no-cache",
} as const;

const appendCloudCredentialResponseHeaders = HttpEffect.appendPreResponseHandler(
  (_request, response) =>
    Effect.succeed(HttpServerResponse.setHeaders(response, CLOUD_CREDENTIAL_RESPONSE_HEADERS)),
);

const internalServerError = (error: { readonly message: string }, cause: unknown) =>
  Effect.logError(error.message, { cause }).pipe(
    Effect.andThen(Effect.fail(new EnvironmentHttpInternalServerError({ message: error.message }))),
  );

const relayFailure = (error: RelayRequestError) => {
  const message = error.message;
  switch (error.rejection) {
    case "unauthorized":
      return Effect.fail(new EnvironmentHttpUnauthorizedError({ message }));
    case "forbidden":
      return Effect.fail(new EnvironmentHttpForbiddenError({ message }));
    case "rejected":
      return Effect.fail(new EnvironmentHttpBadRequestError({ message }));
    case "unavailable":
      return Effect.fail(new EnvironmentHttpInternalServerError({ message }));
  }
};

const badRequest = (error: { readonly message: string }) =>
  Effect.fail(new EnvironmentHttpBadRequestError({ message: error.message }));
const unauthorized = (error: { readonly message: string }) =>
  Effect.fail(new EnvironmentHttpUnauthorizedError({ message: error.message }));
const conflict = (error: { readonly message: string }) =>
  Effect.fail(new EnvironmentHttpConflictError({ message: error.message }));

/** How a connect route answers each CloudLink failure. Messages carry through unchanged. */
const connectErrorCases = {
  CloudLinkRelayConfigInvalidError: badRequest,
  CloudLinkOriginInvalidError: badRequest,
  CloudLinkNotLinkedError: badRequest,
  CloudLinkAccountMismatchError: conflict,
  CloudLinkAuthorizationMissingError: unauthorized,
  CloudLinkProofRejectedError: unauthorized,
  CloudLinkProofReplayedError: conflict,
  CloudLinkTunnelSupersededError: conflict,
  CloudLinkInternalError: (error: CloudLink.CloudLinkInternalError) =>
    internalServerError(error, error.cause),
  RelayRequestError: relayFailure,
} as const;

type ConnectFailure =
  | Exclude<CloudLink.CloudLinkError, CloudLink.CloudLinkEndpointUnavailableError>
  | EnvironmentAuth.ServerAuthInternalError
  | RelayRequestError;

/** Internal failures are logged with their cause before the route answers 500. */
const toHttpError = <A, R>(effect: Effect.Effect<A, ConnectFailure, R>) =>
  effect.pipe(
    Effect.catchTags(connectErrorCases),
    Effect.catchIf(EnvironmentAuth.isServerAuthInternalError, (error) =>
      internalServerError(error, error),
    ),
  );

/** Relay configuration is the one route that answers 503 when the tunnel cannot serve. */
const toHttpErrorOrUnavailable = <A, R>(
  effect: Effect.Effect<A, ConnectFailure | CloudLink.CloudLinkEndpointUnavailableError, R>,
) =>
<<<<<<< HEAD
  HttpClientRequest.post(input.url).pipe(
    HttpClientRequest.bearerToken(input.token),
    HttpClientRequest.bodyJson(input.payload),
    Effect.flatMap(dependencies.httpClient.execute),
    Effect.flatMap(filterRelayResponse),
    Effect.flatMap(HttpClientResponse.schemaBodyJson(input.schema)),
    Effect.timeout(input.timeout ?? "10 seconds"),
    Effect.mapError(relayRequestError),
    withRelayClientTracing,
  );

const reconcileDesiredCloudLinkWith = Effect.fn("environment.cloud.reconcileDesiredLinkWith")(
  function* (dependencies: CloudHttpDependencies, localOrigin: string) {
    const parsedOrigin = yield* Effect.try({
      try: () => parseManagedEndpointLocalOrigin(localOrigin),
      catch: () =>
        new EnvironmentHttpBadRequestError({
          message: "Could not resolve local environment origin.",
        }),
    });
    const token = yield* dependencies.cliTokenManager.getExisting.pipe(
      Effect.flatMap(
        Option.match({
          onNone: () =>
            Effect.fail(
              new EnvironmentHttpUnauthorizedError({
                message: "Run `t3 connect link` to authorize this environment.",
              }),
            ),
          onSome: Effect.succeed,
        }),
      ),
    );
    const mode = yield* readCliDesiredLinkMode;
    const managedTunnelsEnabled = mode !== "publish_only";
    const relayUrl = yield* requireRelayUrl;
    const challenge = yield* relayClientRequest(dependencies, {
      url: `${relayUrl}/v1/client/environment-link-challenges`,
      token: token.accessToken,
      payload: {
        notificationsEnabled: true,
        liveActivitiesEnabled: true,
        managedTunnelsEnabled,
      },
      schema: RelayEnvironmentLinkChallengeResponse,
    });
    const proof = yield* makeCloudLinkProof(
      dependencies,
      {
        challenge: challenge.challenge,
        relayIssuer: relayUrl,
        endpoint: {
          httpBaseUrl: parsedOrigin.httpBaseUrl,
          wsBaseUrl: parsedOrigin.wsBaseUrl,
          providerKind: managedTunnelsEnabled ? "cloudflare_tunnel" : "manual",
        },
        origin: parsedOrigin.origin,
      },
      parsedOrigin.httpBaseUrl,
    );
    const link = yield* relayClientRequest(dependencies, {
      url: `${relayUrl}/v1/client/environment-links`,
      token: token.accessToken,
      payload: {
        proof,
        notificationsEnabled: true,
        liveActivitiesEnabled: true,
        managedTunnelsEnabled,
      },
      schema: RelayEnvironmentLinkResponse,
      timeout: MANAGED_ENDPOINT_PROVISION_REQUEST_TIMEOUT,
    });
    yield* setCliDesiredCloudLink(true, mode);
    yield* applyCloudRelayConfig(
      dependencies,
      {
        relayUrl,
        relayIssuer: link.relayIssuer,
        cloudUserId: link.cloudUserId,
        environmentCredential: link.environmentCredential,
        cloudMintPublicKey: link.cloudMintPublicKey,
        endpointRuntime: link.endpointRuntime,
      },
      {
        lockHeld: true,
        confirmedOrigin: parsedOrigin.origin,
      },
    );
    // Callers decide on managed tunnel recovery from the mode this link
    // actually used, not from a value read before the relay round trip.
    return mode;
  },
  Effect.catchIf(
    ServerSecretStore.isSecretStoreError,
    failEnvironmentCloudInternalError(`Could not persist desired ${CONNECT_NAME} link state.`),
  ),
  Effect.catchTags({
    CloudCliCredentialRemovalError: failCloudCliTokenManagerError,
    CloudCliCredentialRefreshError: failCloudCliTokenManagerError,
    CloudCliCredentialReadError: failCloudCliTokenManagerError,
    CloudCliAuthorizationError: failCloudCliTokenManagerError,
    CloudCliAuthorizationTimeoutError: failCloudCliTokenManagerError,
  }),
);

export const reconcileDesiredCloudLink = Effect.fn("environment.cloud.reconcileDesiredLink")(
  function* (localOrigin: string) {
    const dependencies = yield* cloudHttpDependencies;
    return yield* dependencies.endpointRuntime.withLinkStateLock(
      reconcileDesiredCloudLinkWith(dependencies, localOrigin),
    );
  },
);

export const reconcileDesiredCloudLinkIfStillDesired = Effect.fn(
  "environment.cloud.reconcileDesiredLinkIfStillDesired",
)(function* (localOrigin: string) {
  const dependencies = yield* cloudHttpDependencies;
  return yield* dependencies.endpointRuntime.withLinkStateLock(
    Effect.gen(function* () {
      if (!(yield* readCliDesiredCloudLink)) {
        return null;
      }
      return yield* reconcileDesiredCloudLinkWith(dependencies, localOrigin);
=======
  effect.pipe(
    Effect.catchTags({
      ...connectErrorCases,
      CloudLinkEndpointUnavailableError: (error) =>
        Effect.fail(
          new EnvironmentCloudEndpointUnavailableError({
            message: error.message,
            endpointRuntimeStatus: error.endpointRuntimeStatus,
          }),
        ),
>>>>>>> upstream-sync-cd41c4ada-upstream-renamed
    }),
    Effect.catchIf(EnvironmentAuth.isServerAuthInternalError, (error) =>
      internalServerError(error, error),
    ),
  );

<<<<<<< HEAD
export const registerManagedCloudTunnelRecovery = Effect.fn(
  "environment.cloud.registerManagedCloudTunnelRecovery",
)(function* (localOrigin: string, options?: { readonly retryRuntimeFailures?: boolean }) {
  const dependencies = yield* cloudHttpDependencies;
  const [runtimeConfig, relayUrl, cloudUserId, environmentCredential] = yield* Effect.all([
    dependencies.secrets.get(CLOUD_ENDPOINT_RUNTIME_CONFIG),
    dependencies.secrets.get(RELAY_URL_SECRET),
    dependencies.secrets.get(CLOUD_LINKED_USER_ID),
    dependencies.secrets.get(RELAY_ENVIRONMENT_CREDENTIAL_SECRET),
  ]);
  if (
    Option.isNone(runtimeConfig) ||
    Option.isNone(relayUrl) ||
    Option.isNone(cloudUserId) ||
    Option.isNone(environmentCredential)
  ) {
    return { status: "not_linked" as const };
  }

  const config = Option.getOrNull(decodeRuntimeConfig(bytesToString(runtimeConfig.value)));
  if (config?.providerKind !== "cloudflare_tunnel") {
    return { status: "not_linked" as const };
  }

  const parsedOrigin = yield* Effect.try({
    try: () => parseManagedEndpointLocalOrigin(localOrigin),
    catch: () =>
      new EnvironmentHttpBadRequestError({
        message: "Could not resolve local environment origin.",
      }),
  });
  if (config.tunnelId === undefined) {
    return { status: "recovery_required" as const, config };
  }
  const origin = parsedOrigin.origin;
  const environmentId = yield* dependencies.environment.getEnvironmentId;
  const relayUrlValue = bytesToString(relayUrl.value);
  const cloudUserIdValue = bytesToString(cloudUserId.value);
  const proof = yield* makeManagedTunnelRecoveryProof(dependencies, {
    action: "register",
    environmentId,
    cloudUserId: cloudUserIdValue,
    relayUrl: relayUrlValue,
    tunnelId: config.tunnelId,
    origin,
  });
  const registered = yield* relayClientRequest(dependencies, {
    url: `${relayUrlValue}/v1/environments/${encodeURIComponent(environmentId)}/tunnel/recovery`,
    token: bytesToString(environmentCredential.value),
    payload: {
      cloudUserId: cloudUserIdValue,
      tunnelId: config.tunnelId,
      origin,
      proof,
    },
    schema: RelayManagedEndpointRecoveryRegistrationResponse,
  });
  if (registered.status === "recovery_required") {
    return { status: registered.status, config };
  }
  const endpointRuntimeStatus = yield* activateManagedTunnelWithRetry(
    dependencies,
    {
      config,
      configJson: bytesToString(runtimeConfig.value),
      origin,
    },
    options?.retryRuntimeFailures === true,
  );
  return endpointRuntimeStatus === null
    ? { status: "superseded" as const }
    : { status: "ready" as const, endpointRuntimeStatus };
});

export const recoverManagedCloudTunnel = Effect.fn("environment.cloud.recoverManagedCloudTunnel")(
  function* (
    localOrigin: string,
    expectedConfig?: RelayManagedEndpointRuntimeConfig,
    options?: { readonly retryRuntimeFailures?: boolean },
  ) {
    const dependencies = yield* cloudHttpDependencies;
    const [runtimeConfig, relayUrl, cloudUserId, environmentCredential] = yield* Effect.all([
      dependencies.secrets.get(CLOUD_ENDPOINT_RUNTIME_CONFIG),
      dependencies.secrets.get(RELAY_URL_SECRET),
      dependencies.secrets.get(CLOUD_LINKED_USER_ID),
      dependencies.secrets.get(RELAY_ENVIRONMENT_CREDENTIAL_SECRET),
    ]);
    if (
      Option.isNone(runtimeConfig) ||
      Option.isNone(relayUrl) ||
      Option.isNone(cloudUserId) ||
      Option.isNone(environmentCredential)
    ) {
      return false;
    }
    if (expectedConfig !== undefined) {
      const current = Option.getOrNull(decodeRuntimeConfig(bytesToString(runtimeConfig.value)));
      if (
        current === null ||
        current.providerKind !== expectedConfig.providerKind ||
        current.connectorToken !== expectedConfig.connectorToken ||
        current.tunnelId !== expectedConfig.tunnelId ||
        current.tunnelName !== expectedConfig.tunnelName
      ) {
        return false;
      }
    }

    const parsedOrigin = yield* Effect.try({
      try: () => parseManagedEndpointLocalOrigin(localOrigin),
      catch: () =>
        new EnvironmentHttpBadRequestError({
          message: "Could not resolve local environment origin.",
        }),
    });

    const environmentId = yield* dependencies.environment.getEnvironmentId;
    const relayUrlValue = bytesToString(relayUrl.value);
    const cloudUserIdValue = bytesToString(cloudUserId.value);
    const origin = parsedOrigin.origin;
    const proof = yield* makeManagedTunnelRecoveryProof(dependencies, {
      action: "recover",
      environmentId,
      cloudUserId: cloudUserIdValue,
      relayUrl: relayUrlValue,
      origin,
    });
    const recovered = yield* relayClientRequest(dependencies, {
      url: `${relayUrlValue}/v1/environments/${encodeURIComponent(environmentId)}/tunnel`,
      token: bytesToString(environmentCredential.value),
      payload: {
        cloudUserId: cloudUserIdValue,
        origin,
        proof,
      },
      schema: RelayManagedEndpointRecoveryResponse,
      timeout: MANAGED_ENDPOINT_PROVISION_REQUEST_TIMEOUT,
    });
    if (recovered.endpointRuntime.providerKind !== "cloudflare_tunnel") {
      return yield* new EnvironmentHttpInternalServerError({
        message: `${CONNECT_NAME} returned an unsupported managed tunnel configuration.`,
      });
    }

    const encoded = yield* encodeEndpointRuntimeConfigJson(recovered.endpointRuntime).pipe(
      Effect.mapError(
        () =>
          new EnvironmentHttpInternalServerError({
            message: "Could not persist the recovered managed tunnel configuration.",
          }),
      ),
    );
    const stored = yield* dependencies.endpointRuntime.withLinkStateLock(
      Effect.gen(function* () {
        const currentConfig = yield* dependencies.secrets.get(CLOUD_ENDPOINT_RUNTIME_CONFIG);
        if (
          Option.isNone(currentConfig) ||
          bytesToString(currentConfig.value) !== bytesToString(runtimeConfig.value)
        ) {
          return false;
        }
        yield* dependencies.secrets.set(CLOUD_ENDPOINT_RUNTIME_CONFIG, stringToBytes(encoded));
        yield* dependencies.secrets.remove(CLOUD_ENDPOINT_CONFIRMED_ORIGIN);
        return true;
      }),
    );
    if (!stored) return false;
    const status = yield* activateManagedTunnelWithRetry(
      dependencies,
      {
        config: recovered.endpointRuntime,
        configJson: encoded,
        origin,
      },
      options?.retryRuntimeFailures === true,
    );
    return status !== null;
  },
);

// The launcher owns this durable state, so read it directly both when a trial
// decides whether it owns pre-activation cleanup and while a server tears down.
export const pendingServiceUpdateExists = Effect.gen(function* () {
  const config = yield* ServerConfig.ServerConfig;
  const fs = yield* FileSystem.FileSystem;
  const path = yield* Path.Path;
  const runtimeDir = path.join(config.baseDir, "runtime");
  const stateText = yield* fs
    .readFileString(path.join(runtimeDir, SERVICE_STATE_FILE))
    .pipe(Effect.option);
  return Option.isSome(stateText) && serviceStateHasPendingUpdate(stateText.value);
});

// A pending update alone is not proof a replacement server is coming: an
// explicit launcher stop (`t3 service uninstall`, `systemctl stop`,
// `launchctl bootout`) during
// the pending window also tears this server down. The launcher marks that case
// just before it signals the child, so pending + no marker is the handoff.
const pendingUpdateHandoffExists = Effect.gen(function* () {
  if (!(yield* pendingServiceUpdateExists)) {
    return false;
  }
  const config = yield* ServerConfig.ServerConfig;
  const fs = yield* FileSystem.FileSystem;
  const path = yield* Path.Path;
  const runtimeDir = path.join(config.baseDir, "runtime");
  const stopping = yield* fs
    .exists(path.join(runtimeDir, SERVICE_STOP_MARKER_FILE))
    .pipe(Effect.orElseSucceed(() => false));
  return !stopping;
});

// The desktop app writes its marker right before it stops this server to
// install an update, whether a remote client or the local app started it.
// Reading consumes it, so shutdown checks it first. Only a fresh marker counts,
// so a marker the server never read (a hard kill) cannot keep the tunnel on a
// later quit.
const desktopUpdateRestartPending = Effect.gen(function* () {
  const config = yield* ServerConfig.ServerConfig;
  const fs = yield* FileSystem.FileSystem;
  const path = yield* Path.Path;
  const markerPath = path.join(config.baseDir, "runtime", DESKTOP_UPDATE_RESTART_MARKER_FILE);
  const marker = yield* fs.stat(markerPath).pipe(Effect.option);
  if (Option.isNone(marker)) {
    return false;
  }
  yield* fs.remove(markerPath).pipe(Effect.ignore);
  const now = yield* Clock.currentTimeMillis;
  return Option.match(marker.value.mtime, {
    onNone: () => false,
    onSome: (writtenAt) =>
      now - writtenAt.getTime() < Duration.toMillis(DESKTOP_UPDATE_RESTART_MARKER_TTL),
  });
});

// Cloudflare bills per provisioned tunnel, so an environment that goes offline
// must not leave its tunnel behind. Releasing deletes only the tunnel — the
// relay keeps the link and its hostname reservation, and the next startup's
// link reconcile provisions a replacement tunnel under the same URL.
export const releaseManagedTunnelOnShutdown = Effect.fn(
  "environment.cloud.releaseManagedTunnelOnShutdown",
)(function* () {
  const dependencies = yield* cloudHttpDependencies;
  // Only a managed link stores a runtime config; publish-only links have no
  // tunnel to release.
  const runtimeConfig = yield* dependencies.secrets.get(CLOUD_ENDPOINT_RUNTIME_CONFIG);
  if (Option.isNone(runtimeConfig)) {
    return false;
  }
  // Only CLI-desired managed links release eagerly because this request uses
  // CLI authorization. Web/mobile links register startup recovery with their
  // environment credential, and the relay reaper removes them after they are
  // down for the configured grace period. Unlink still deletes either kind.
  if (!(yield* readCliDesiredCloudLink) || (yield* readCliDesiredLinkMode) !== "managed") {
    return false;
  }
  // A shutdown that hands off to a pending update is not the environment
  // going offline: the service launcher or the desktop app immediately brings
  // a server back (the new version, or the old one after a rollback). Deleting
  // the tunnel here forces that server to provision a replacement UUID, and the
  // public hostname's route to the new tunnel takes 1-2 minutes to propagate —
  // the dominant cost of an update restart. Keep the tunnel instead: the next
  // boot respawns the connector from the stored config and is reachable as
  // soon as it connects, and the reconcile confirms the still-live tunnel
  // without replacing it.
  if ((yield* desktopUpdateRestartPending) || (yield* pendingUpdateHandoffExists)) {
    yield* Effect.logInfo("Keeping the managed tunnel across the update restart");
    return false;
  }
  const token = yield* dependencies.cliTokenManager.getExisting;
  if (Option.isNone(token)) {
    return false;
  }
  // The link belongs to the relay it was installed against, so target the
  // persisted URL: T3CODE_RELAY_URL may have changed since the link was made.
  const relayUrl = yield* dependencies.secrets.get(RELAY_URL_SECRET);
  if (Option.isNone(relayUrl)) {
    return false;
  }
  const environmentId = yield* dependencies.environment.getEnvironmentId;
  // Stop the local connector before the relay deletes the tunnel it serves.
  yield* dependencies.endpointRuntime.applyConfig(null);
  const response = yield* HttpClientRequest.delete(
    `${bytesToString(relayUrl.value)}/v1/client/environment-links/${encodeURIComponent(environmentId)}/tunnel`,
  ).pipe(
    HttpClientRequest.bearerToken(token.value.accessToken),
    dependencies.httpClient.execute,
    Effect.flatMap(filterRelayResponse),
    Effect.flatMap(HttpClientResponse.schemaBodyJson(RelayOkResponse)),
    withRelayClientTracing,
  );
  // ok:false means the relay skipped deletion because a concurrent provision
  // owns the recorded tunnel now — leave the stored config alone.
  if (!response.ok) {
    return false;
  }
  // The connector token died with the tunnel. Drop the stored config so the
  // next start waits for the link reconcile instead of respawning the relay
  // client with a dead token. Kept when the release request fails: the tunnel
  // still exists, so the stored token keeps working across the restart.
  // Only dropped while it is still the config this shutdown released — a fast
  // restart may already have reconciled and stored a fresh config for its
  // replacement tunnel, and that one must survive this finalizer.
  const storedConfig = yield* dependencies.secrets.get(CLOUD_ENDPOINT_RUNTIME_CONFIG);
  if (
    Option.isSome(storedConfig) &&
    bytesToString(storedConfig.value) === bytesToString(runtimeConfig.value)
  ) {
    yield* dependencies.secrets.remove(CLOUD_ENDPOINT_RUNTIME_CONFIG);
    yield* dependencies.secrets.remove(CLOUD_ENDPOINT_CONFIRMED_ORIGIN);
  }
  return true;
});

const readCloudLinkState = Effect.fn("environment.cloud.readLinkState")(function* (
  dependencies: CloudHttpDependencies,
) {
  const [cloudUserId, relayUrl, relayIssuer, endpointRuntimeConfig, publishAgentActivity] =
    yield* Effect.all(
      [
        dependencies.secrets.get(CLOUD_LINKED_USER_ID),
        dependencies.secrets.get(RELAY_URL_SECRET),
        dependencies.secrets.get(RELAY_ISSUER_SECRET),
        dependencies.secrets.get(CLOUD_ENDPOINT_RUNTIME_CONFIG),
        dependencies.secrets.get(PUBLISH_AGENT_ACTIVITY_SECRET),
      ],
      { concurrency: 5 },
    );
  return {
    linked: Option.isSome(cloudUserId),
    cloudUserId: Option.isSome(cloudUserId) ? bytesToString(cloudUserId.value) : null,
    relayUrl: Option.isSome(relayUrl) ? bytesToString(relayUrl.value) : null,
    relayIssuer: Option.isSome(relayIssuer) ? bytesToString(relayIssuer.value) : null,
    // The managed tunnel runtime config is only stored for managed links; a
    // publish-only link leaves it absent.
    managedTunnelActive: Option.isSome(endpointRuntimeConfig),
    publishAgentActivity: Option.isSome(publishAgentActivity)
      ? bytesToString(publishAgentActivity.value) === "true"
      : false,
  } satisfies EnvironmentCloudLinkStateResult;
});

const cloudLinkStateHandler = Effect.fn("environment.cloud.linkState")(
  function* (dependencies: CloudHttpDependencies) {
    yield* requireEnvironmentScope(AuthRelayReadScope);
    return yield* readCloudLinkState(dependencies);
  },
  Effect.catchIf(
    ServerSecretStore.isSecretStoreError,
    failEnvironmentCloudInternalError("Could not read environment relay configuration."),
  ),
);

const cloudUnlinkHandler = Effect.fn("environment.cloud.unlink")(
  function* (dependencies: CloudHttpDependencies) {
    yield* requireEnvironmentScope(AuthRelayWriteScope);
    return yield* dependencies.endpointRuntime.withLinkStateLock(
      Effect.gen(function* () {
        const endpointRuntimeStatus = yield* dependencies.endpointRuntime.applyConfig(null);
        yield* Effect.all(
          [
            dependencies.secrets.remove(CLOUD_LINKED_USER_ID),
            dependencies.secrets.remove(RELAY_URL_SECRET),
            dependencies.secrets.remove(RELAY_ISSUER_SECRET),
            dependencies.secrets.remove(RELAY_ENVIRONMENT_CREDENTIAL_SECRET),
            dependencies.secrets.remove(CLOUD_MINT_PUBLIC_KEY),
            dependencies.secrets.remove(CLOUD_ENDPOINT_RUNTIME_CONFIG),
            dependencies.secrets.remove(CLOUD_ENDPOINT_CONFIRMED_ORIGIN),
            dependencies.secrets.remove(PUBLISH_AGENT_ACTIVITY_SECRET),
          ],
          { concurrency: 8 },
        );
        yield* setCliDesiredCloudLink(false);
        return { ok: true, endpointRuntimeStatus } satisfies EnvironmentCloudRelayConfigResult;
      }),
    );
  },
  Effect.catchIf(
    ServerSecretStore.isSecretStoreError,
    failEnvironmentCloudInternalError("Could not remove environment relay configuration."),
  ),
);

const cloudPreferencesHandler = Effect.fn("environment.cloud.preferences")(
  function* (
    dependencies: CloudHttpDependencies,
    payload: { readonly publishAgentActivity: boolean },
  ) {
    yield* requireEnvironmentScope(AuthRelayWriteScope);
    yield* dependencies.secrets.set(
      PUBLISH_AGENT_ACTIVITY_SECRET,
      stringToBytes(String(payload.publishAgentActivity)),
    );
    yield* dependencies.awarenessRelay.requestCatchUp();
    return yield* readCloudLinkState(dependencies);
  },
  Effect.catchIf(
    ServerSecretStore.isSecretStoreError,
    failEnvironmentCloudInternalError("Could not persist environment cloud preferences."),
  ),
);

const cloudEnvironmentHealthHandler = Effect.fn("environment.cloud.health")(
  function* (dependencies: CloudHttpDependencies, request: RelayCloudEnvironmentHealthRequest) {
    const cloudMintPublicKey = yield* dependencies.secrets
      .get(CLOUD_MINT_PUBLIC_KEY)
      .pipe(
        Effect.flatMap((bytes) =>
          Option.isSome(bytes)
            ? Effect.succeed(bytesToString(bytes.value))
            : Effect.fail(new EnvironmentAuth.ServerAuthCloudMintPublicKeyMissingError({})),
        ),
      );
    const relayIssuer = yield* dependencies.secrets
      .get(RELAY_ISSUER_SECRET)
      .pipe(
        Effect.flatMap((bytes) =>
          Option.isSome(bytes)
            ? Effect.succeed(bytesToString(bytes.value))
            : dependencies.secrets
                .get(RELAY_URL_SECRET)
                .pipe(
                  Effect.flatMap((fallbackBytes) =>
                    Option.isSome(fallbackBytes)
                      ? Effect.succeed(bytesToString(fallbackBytes.value))
                      : Effect.fail(new EnvironmentAuth.ServerAuthCloudRelayIssuerMissingError({})),
                  ),
                ),
        ),
      );
    const environmentId = yield* dependencies.environment.getEnvironmentId;
    const linkedCloudUserId = yield* readInstalledCloudUserId(dependencies.secrets);
    const now = yield* DateTime.now;
    const nowSeconds = Math.floor(now.epochMilliseconds / 1_000);
    const proofOption = yield* verifyRelayJwt({
      publicKey: cloudMintPublicKey,
      token: request.proof,
      typ: RELAY_HEALTH_REQUEST_TYP,
      issuer: normalizeRelayIssuer(relayIssuer),
      audience: `t3-env:${environmentId}`,
      nowEpochSeconds: nowSeconds,
    }).pipe(Effect.flatMap(decodeCloudHealthProof), Effect.option);
    if (
      Option.isNone(proofOption) ||
      proofOption.value.environmentId !== environmentId ||
      proofOption.value.sub !== linkedCloudUserId ||
      !hasBoundedCloudProofLifetime({ ...proofOption.value, nowSeconds }) ||
      !hasExactScope({ scopes: proofOption.value.scope, expected: "environment:status" })
    ) {
      return yield* new EnvironmentHttpUnauthorizedError({
        message: "Invalid cloud health request.",
      });
    }
    const proof = proofOption.value;

    const jtiSecretName = `${CLOUD_HEALTH_JTI_PREFIX}${proof.jti}`;
    const nonceSecretName = `${CLOUD_HEALTH_NONCE_PREFIX}${proof.nonce}`;
    const consumedReplayGuards = yield* consumeCloudReplayGuards({
      secrets: dependencies.secrets,
      names: [jtiSecretName, nonceSecretName],
      value: stringToBytes(DateTime.formatIso(now)),
    });
    if (!consumedReplayGuards) {
      return yield* new EnvironmentHttpConflictError({
        message: "Cloud health request was already consumed.",
      });
    }

    const keyPair = yield* getOrCreateEnvironmentKeyPairFromSecretStore(dependencies.secrets);
    const descriptor = yield* dependencies.environment.getDescriptor;
    const responseExpiresAt = DateTime.add(now, { minutes: 5 });
    const responsePayload = {
      iss: `t3-env:${environmentId}`,
      aud: normalizeRelayIssuer(relayIssuer),
      sub: environmentId,
      jti: yield* Crypto.Crypto.pipe(Effect.flatMap((crypto) => crypto.randomUUIDv4)),
      iat: nowSeconds,
      exp: Math.floor(responseExpiresAt.epochMilliseconds / 1_000),
      environmentId,
      requestNonce: proof.nonce,
      status: "online",
      descriptor,
      checkedAt: DateTime.formatIso(now),
    } satisfies RelayEnvironmentHealthResponseProofPayload;
    const responseProof = yield* signRelayJwt({
      privateKey: keyPair.privateKey,
      typ: RELAY_HEALTH_RESPONSE_TYP,
      payload: responsePayload,
    }).pipe(
      Effect.mapError(
        (cause) =>
          new EnvironmentAuth.ServerAuthCloudHealthJwtSigningError({
            cause,
          }),
      ),
    );
    const response = {
      environmentId,
      status: "online",
      descriptor,
      checkedAt: responsePayload.checkedAt,
      proof: responseProof,
    } satisfies RelayEnvironmentHealthResponseShape;

    yield* appendCloudCredentialResponseHeaders;
    return response;
  },
  Effect.catchIf(EnvironmentAuth.isServerAuthInternalError, (error) =>
    failEnvironmentCloudInternalError(error.message)(error),
  ),
  Effect.catchIf(
    ServerSecretStore.isSecretStoreError,
    failEnvironmentCloudInternalError("Could not answer cloud health request."),
  ),
  Effect.catchTag(
    "PlatformError",
    failEnvironmentCloudInternalError("Could not answer cloud health request."),
  ),
);

const cloudMintCredentialHandler = Effect.fn("environment.cloud.mintCredential")(
  function* (dependencies: CloudHttpDependencies, request: RelayCloudMintCredentialRequest) {
    const cloudMintPublicKey = yield* dependencies.secrets
      .get(CLOUD_MINT_PUBLIC_KEY)
      .pipe(
        Effect.flatMap((bytes) =>
          Option.isSome(bytes)
            ? Effect.succeed(bytesToString(bytes.value))
            : Effect.fail(new EnvironmentAuth.ServerAuthCloudMintPublicKeyMissingError({})),
        ),
      );
    const relayIssuer = yield* dependencies.secrets
      .get(RELAY_ISSUER_SECRET)
      .pipe(
        Effect.flatMap((bytes) =>
          Option.isSome(bytes)
            ? Effect.succeed(bytesToString(bytes.value))
            : dependencies.secrets
                .get(RELAY_URL_SECRET)
                .pipe(
                  Effect.flatMap((fallbackBytes) =>
                    Option.isSome(fallbackBytes)
                      ? Effect.succeed(bytesToString(fallbackBytes.value))
                      : Effect.fail(new EnvironmentAuth.ServerAuthCloudRelayIssuerMissingError({})),
                  ),
                ),
        ),
      );
    const environmentId = yield* dependencies.environment.getEnvironmentId;
    const linkedCloudUserId = yield* readInstalledCloudUserId(dependencies.secrets);
    const now = yield* DateTime.now;
    const nowSeconds = Math.floor(now.epochMilliseconds / 1_000);
    const proofOption = yield* verifyRelayJwt({
      publicKey: cloudMintPublicKey,
      token: request.proof,
      typ: RELAY_MINT_REQUEST_TYP,
      issuer: normalizeRelayIssuer(relayIssuer),
      audience: `t3-env:${environmentId}`,
      nowEpochSeconds: nowSeconds,
    }).pipe(Effect.flatMap(decodeCloudMintProof), Effect.option);
    if (
      Option.isNone(proofOption) ||
      proofOption.value.environmentId !== environmentId ||
      proofOption.value.sub !== linkedCloudUserId ||
      proofOption.value.cnf.jkt !== proofOption.value.clientProofKeyThumbprint ||
      !hasBoundedCloudProofLifetime({ ...proofOption.value, nowSeconds }) ||
      !hasExactScope({ scopes: proofOption.value.scope, expected: "environment:connect" })
    ) {
      return yield* new EnvironmentHttpUnauthorizedError({
        message: "Invalid cloud mint request.",
      });
    }
    const proof = proofOption.value;

    const jtiSecretName = `${CLOUD_MINT_JTI_PREFIX}${proof.jti}`;
    const nonceSecretName = `${CLOUD_MINT_NONCE_PREFIX}${proof.nonce}`;
    const consumedReplayGuards = yield* consumeCloudReplayGuards({
      secrets: dependencies.secrets,
      names: [jtiSecretName, nonceSecretName],
      value: stringToBytes(DateTime.formatIso(now)),
    });
    if (!consumedReplayGuards) {
      return yield* new EnvironmentHttpConflictError({
        message: "Cloud mint request was already consumed.",
      });
    }

    const keyPair = yield* getOrCreateEnvironmentKeyPairFromSecretStore(dependencies.secrets);
    const issued = yield* dependencies.environmentAuth.createPairingLink({
      scopes: AuthStandardClientScopes,
      subject: "cloud-connect",
      ttl: Duration.minutes(2),
      label: `${CONNECT_NAME} connect`,
      proofKeyThumbprint: proof.clientProofKeyThumbprint,
    });
    const responsePayload = {
      iss: `t3-env:${environmentId}`,
      aud: normalizeRelayIssuer(relayIssuer),
      sub: environmentId,
      jti: yield* Crypto.Crypto.pipe(Effect.flatMap((crypto) => crypto.randomUUIDv4)),
      iat: nowSeconds,
      exp: Math.floor(issued.expiresAt.epochMilliseconds / 1_000),
      environmentId,
      clientProofKeyThumbprint: proof.clientProofKeyThumbprint,
      requestNonce: proof.nonce,
      credential: issued.credential,
    } satisfies RelayEnvironmentMintResponseProofPayload;
    const responseProof = yield* signRelayJwt({
      privateKey: keyPair.privateKey,
      typ: RELAY_MINT_RESPONSE_TYP,
      payload: responsePayload,
    }).pipe(
      Effect.mapError(
        (cause) =>
          new EnvironmentAuth.ServerAuthCloudMintJwtSigningError({
            cause,
          }),
      ),
    );
    const response = {
      credential: issued.credential,
      expiresAt: DateTime.formatIso(issued.expiresAt),
      proof: responseProof,
    } satisfies RelayEnvironmentMintResponseShape;

    yield* appendCloudCredentialResponseHeaders;
    return response;
  },
  Effect.catchIf(EnvironmentAuth.isServerAuthInternalError, (error) =>
    failEnvironmentCloudInternalError(error.message)(error),
  ),
  Effect.catchIf(
    ServerSecretStore.isSecretStoreError,
    failEnvironmentCloudInternalError("Could not issue cloud connection credential."),
  ),
  Effect.catchTag(
    "PlatformError",
    failEnvironmentCloudInternalError("Could not issue cloud connection credential."),
  ),
);

export const connectHttpApiLayer = HttpApiBuilder.group(
=======
export const layer = HttpApiBuilder.group(
>>>>>>> upstream-sync-cd41c4ada-upstream-renamed
  EnvironmentHttpApi,
  "connect",
  Effect.fnUntraced(function* (handlers) {
    const cloudLink = yield* CloudLink.CloudLink;
    return handlers
      .handle("linkProof", ({ payload }) =>
        Effect.gen(function* () {
          yield* requireEnvironmentScope(AuthRelayWriteScope);
          const request = yield* HttpServerRequest.HttpServerRequest;
          const proof = yield* toHttpError(cloudLink.linkProof(payload, request));
          yield* appendCloudCredentialResponseHeaders;
          return proof;
        }),
      )
      .handle("relayConfig", ({ payload }) =>
        requireEnvironmentScope(AuthRelayWriteScope).pipe(
          Effect.andThen(toHttpErrorOrUnavailable(cloudLink.applyRelayConfig(payload))),
        ),
      )
      .handle("linkState", () =>
        requireEnvironmentScope(AuthRelayReadScope).pipe(
          Effect.andThen(toHttpError(cloudLink.linkState())),
        ),
      )
      .handle("unlink", () =>
        requireEnvironmentScope(AuthRelayWriteScope).pipe(
          Effect.andThen(toHttpError(cloudLink.unlink())),
        ),
      )
      .handle("preferences", ({ payload }) =>
        requireEnvironmentScope(AuthRelayWriteScope).pipe(
          Effect.andThen(toHttpError(cloudLink.updatePreferences(payload))),
        ),
      )
      .handle("health", ({ payload }) =>
        toHttpError(cloudLink.answerHealthRequest(payload)).pipe(
          Effect.tap(() => appendCloudCredentialResponseHeaders),
        ),
      )
      .handle("mintCredential", ({ payload }) =>
        toHttpError(cloudLink.mintCredential(payload)).pipe(
          Effect.tap(() => appendCloudCredentialResponseHeaders),
        ),
      )
      .handle("t3MintCredential", ({ payload }) =>
        traceRelayRequest(
          toHttpError(cloudLink.mintCredential(payload)).pipe(
            Effect.tap(() => appendCloudCredentialResponseHeaders),
          ),
        ),
      );
  }),
);
