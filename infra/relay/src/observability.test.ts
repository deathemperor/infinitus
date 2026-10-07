import { expect, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as Tracer from "effect/Tracer";

import * as EnvironmentConnector from "./environments/EnvironmentConnector.ts";
import * as Observability from "./observability.ts";

it.effect("adds schema error fields to spans on the current tracer", () =>
  Effect.gen(function* () {
    const spans: Array<Tracer.NativeSpan> = [];
    const tracer = Tracer.make({
      span: (options) => {
        const span = new Tracer.NativeSpan(options);
        spans.push(span);
        return span;
      },
    });

    yield* Effect.fail(
      new EnvironmentConnector.EnvironmentConnectNotAuthorized({
        environmentId: "environment-1",
        operation: "connect",
        reason: "managed_endpoint_allocation_not_ready",
      }),
    ).pipe(
      Effect.withSpan("relay.test.schema_error"),
      Effect.exit,
      Observability.withSchemaErrorSpanAttributes,
      Effect.withTracer(tracer),
    );

<<<<<<< HEAD
    const request = yield* Deferred.await(exportedRequest).pipe(Effect.timeout("1 second"));
    const payload = (yield* decodeJson(request.body)) as OtlpTracer.TraceData;
    const resourceAttributes = Object.fromEntries(
      payload.resourceSpans
        .flatMap((resourceSpan) => resourceSpan.resource.attributes)
        .map((attribute) => [attribute.key, otlpAttributeValue(attribute.value)]),
    );
    const span = payload.resourceSpans
      .flatMap((resourceSpan) => resourceSpan.scopeSpans)
      .flatMap((scopeSpan) => scopeSpan.spans)
      .find((candidate) => candidate.name === "relay.test.schema_error");
    const attributes = Object.fromEntries(
      (span?.attributes ?? []).map((attribute) => [
        attribute.key,
        otlpAttributeValue(attribute.value),
      ]),
    );

    expect(request.authorization).toBe("Bearer test-token");
    expect(request.dataset).toBe("relay-test-traces");
    expect(resourceAttributes).toMatchObject({
      "service.name": "infinitus-relay-worker",
      "service.namespace": "t3code",
    });
    expect(attributes).toMatchObject({
=======
    expect(spans.map((span) => span.name)).toEqual(["relay.test.schema_error"]);
    expect(Object.fromEntries(spans[0]!.attributes)).toMatchObject({
>>>>>>> upstream-sync-079e4bccd-upstream-renamed
      "error.type": "EnvironmentConnectNotAuthorized",
      "error.environmentId": "environment-1",
      "error.operation": "connect",
      "error.reason": "managed_endpoint_allocation_not_ready",
    });
  }),
);
