import { ProviderSetupError, type CodexAuthCallbackInput } from "@infinitus/contracts";
import { receiveCodexAuthCallback } from "@infinitus/shared/codexAuthCallback";
import { codexAuthorizationRequest } from "@infinitus/shared/codexAuthHandoff";
import { providerAuthReturnUrl } from "@infinitus/shared/providerAuthReturnUrl";
import { isLoopbackHost } from "@infinitus/shared/preview";
import * as Deferred from "effect/Deferred";
import * as Effect from "effect/Effect";
import * as Fiber from "effect/Fiber";
import * as Stream from "effect/Stream";
import { PRODUCT_NAME } from "@infinitus/shared/productName";

/** A connected local environment receives the callback; only the remote environment owns tokens. */
export function subscribeCodexAuthCallback(input: CodexAuthCallbackInput) {
  const failure = (error: unknown) =>
    new ProviderSetupError({
      instanceId: input.instanceId,
      operation: "callback",
      detail:
        error instanceof Error ? error.message : "Could not receive sign-in on this computer.",
    });
  return Stream.unwrap(
    Effect.gen(function* () {
      const destination = yield* Effect.try({
        try: () => {
          codexAuthorizationRequest(input.authorizationUrl);
          const destination = providerAuthReturnUrl(input.returnUrl);
          if (!destination || !isLoopbackHost(new URL(destination).hostname))
            throw new Error(
              `The local sign-in receiver needs a local ${PRODUCT_NAME} return address.`,
            );
          return destination;
        },
        catch: failure,
      });
      const ready = yield* Deferred.make<void, ProviderSetupError>();
      const runSync = Effect.runSyncWith(yield* Effect.context<never>());
      const callback = yield* Effect.tryPromise({
        try: (signal) =>
          receiveCodexAuthCallback(
            input.authorizationUrl,
            async () => {
              runSync(Deferred.succeed(ready, undefined));
              return true;
            },
            () => destination,
            signal,
          ),
        catch: failure,
      }).pipe(
        Effect.tapError((error) => Deferred.fail(ready, error)),
        Effect.forkScoped,
      );
      return Stream.fromEffect(Deferred.await(ready)).pipe(
        Stream.map(() => ({ phase: "ready" as const })),
        Stream.concat(
          Stream.fromEffect(Fiber.join(callback)).pipe(
            Stream.map((callbackUrl) => ({ phase: "finished" as const, callbackUrl })),
          ),
        ),
      );
    }),
  );
}
