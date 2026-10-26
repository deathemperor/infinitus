import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import * as GitWorkflow from "../git/GitWorkflowService.ts";
import * as ProjectService from "../project/ProjectService.ts";
import { TurnStartGatePassthrough } from "./TurnStartGate.ts";

export const layer = Layer.mergeAll(
  // Fork (#720, #1627): the turn-start gate the service requires; tests run every start at once.
  TurnStartGatePassthrough,
  Layer.mock(GitWorkflow.GitWorkflowService)({
    pruneWorktrees: () => Effect.void,
    createWorktree: () => Effect.succeed({} as never),
  }),
  Layer.mock(ProjectService.ProjectService)({
    getById: () => Effect.succeedNone,
  }),
);
