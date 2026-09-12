import { MessageId, OrchestrationMessageContext, QueueId, ThreadId } from "@t3tools/contracts";
import { assert, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Schema from "effect/Schema";

import { SqlitePersistenceMemory } from "./Layers/Sqlite.ts";
import {
  ProjectionThreadQueuedTurnRepository,
  layer as repositoryLayer,
} from "./ProjectionThreadQueuedTurns.ts";

const layer = it.layer(repositoryLayer.pipe(Layer.provideMerge(SqlitePersistenceMemory)));

const context = Schema.decodeUnknownSync(OrchestrationMessageContext)({
  version: 1,
  records: [{ version: 1, contextId: "ctx-1", label: "a.ts", kind: "mention", path: "src/a.ts" }],
});

layer("ProjectionThreadQueuedTurnRepository (#969)", (it) => {
  it.effect("round-trips the message's context records, null when there are none", () =>
    Effect.gen(function* () {
      const repository = yield* ProjectionThreadQueuedTurnRepository;
      const threadId = ThreadId.make("thread-queued-context");
      const base = {
        threadId,
        attachments: [],
        modelSelection: null,
        createdAt: "2026-09-12T10:00:00.000Z",
        updatedAt: "2026-09-12T10:00:00.000Z",
      };
      yield* repository.upsert({
        ...base,
        queueId: QueueId.make("q-with"),
        messageId: MessageId.make("m-with"),
        text: "with",
        context,
        orderKey: "a",
      });
      yield* repository.upsert({
        ...base,
        queueId: QueueId.make("q-without"),
        messageId: MessageId.make("m-without"),
        text: "without",
        context: null,
        orderKey: "b",
      });

      const rows = yield* repository.listByThreadId({ threadId });
      assert.deepEqual(
        rows.map((row) => row.queueId),
        ["q-with", "q-without"],
      );
      assert.deepEqual(
        rows.map((row) => row.context),
        [context, null],
      );
    }),
  );
});
