import * as Rpc from "effect/rpc/Rpc";
import * as Schema from "effect/Schema";

import { EnvironmentAuthorizationError } from "./auth.ts";
import {
  CaptureList,
  CaptureListFull,
  CapturesApplyInput,
  CapturesApplyResult,
  CaptureStoreError,
  CapturesSubscribeInput,
} from "./captures.ts";
import {
  InfinitusCommandFailed,
  InfinitusCommandInput,
  InfinitusCommandResult,
  InfinitusHeldThread,
  InfinitusLaunchResult,
  InfinitusLimitStops,
  InfinitusProtocolError,
  InfinitusReleaseThreadInput,
  InfinitusReleaseThreadResult,
  InfinitusSecretInput,
  InfinitusSecretRefused,
  InfinitusSecretResult,
  InfinitusSnapshot,
  InfinitusSubscribeInput,
  InfinitusUnavailable,
} from "./infinitus.ts";
import {
  PairingApprovalDecideInput,
  PairingApprovalDecideResult,
  PairingApprovalIssueFailed,
  PairingApprovalPendingRequests,
} from "./infinitusPairing.ts";
import { StatsRequest, StatsSnapshot } from "./stats.ts";
import { UsageReadError } from "./usage.ts";

/** The fork's WebSocket methods, spread into upstream's `WS_METHODS`. */
export const INFINITUS_WS_METHODS = {
  serverGetStats: "server.getStats",
  subscribeInfinitus: "subscribeInfinitus",
  infinitusCommand: "infinitus.command",
  infinitusLaunch: "infinitus.launch",
  infinitusSecret: "infinitus.secret",
  subscribeInfinitusPairing: "subscribeInfinitusPairing",
  infinitusPairingDecide: "infinitus.pairingDecide",
  // Session priority mode (#616, #743): the server's holds and "Run now".
  subscribeInfinitusHolds: "subscribeInfinitusHolds",
  infinitusReleaseThread: "infinitus.releaseThread",
  subscribeInfinitusLimitStops: "subscribeInfinitusLimitStops",
  subscribeCaptures: "subscribeCaptures",
  capturesApply: "captures.apply",
} as const;

/** The Stats page's fold (#659). */
const WsServerGetStatsRpc = Rpc.make(INFINITUS_WS_METHODS.serverGetStats, {
  payload: StatsRequest,
  success: StatsSnapshot,
  error: Schema.Union([EnvironmentAuthorizationError, UsageReadError]),
});

/** The whole Infinitus view, seeded with the current snapshot and followed by
    every change. Unreachability is a snapshot with `available: false`, never a
    stream failure: the app comes and goes while a client stays subscribed. */
const WsSubscribeInfinitusRpc = Rpc.make(INFINITUS_WS_METHODS.subscribeInfinitus, {
  payload: InfinitusSubscribeInput,
  success: InfinitusSnapshot,
  error: EnvironmentAuthorizationError,
  stream: true,
});

/** Asks the server's host to open the Infinitus menu-bar app when its control
    socket is not answering. Never fails: an unsupported host or a failed
    `open` is a `launched: false` with the reason. */
const WsInfinitusLaunchRpc = Rpc.make(INFINITUS_WS_METHODS.infinitusLaunch, {
  payload: Schema.Struct({}),
  success: InfinitusLaunchResult,
  error: EnvironmentAuthorizationError,
});

/** The requests waiting for this desktop's approval (#710): the current list,
    then the whole list again on every change. Metadata only. */
const WsSubscribeInfinitusPairingRpc = Rpc.make(INFINITUS_WS_METHODS.subscribeInfinitusPairing, {
  payload: Schema.Struct({}),
  success: PairingApprovalPendingRequests,
  error: EnvironmentAuthorizationError,
  stream: true,
});

/** Approves or denies one pending request. Approving mints the one-time
    pairing credential the phone then collects by polling; it never rides
    this reply. */
const WsInfinitusPairingDecideRpc = Rpc.make(INFINITUS_WS_METHODS.infinitusPairingDecide, {
  payload: PairingApprovalDecideInput,
  success: PairingApprovalDecideResult,
  error: Schema.Union([EnvironmentAuthorizationError, PairingApprovalIssueFailed]),
});

/** The threads the server holds for headroom (#616, #741) or paused for it
    (#743): the whole list on subscribe, then again on every change. */
const WsSubscribeInfinitusHoldsRpc = Rpc.make(INFINITUS_WS_METHODS.subscribeInfinitusHolds, {
  payload: Schema.Struct({}),
  success: Schema.Array(InfinitusHeldThread),
  error: EnvironmentAuthorizationError,
  stream: true,
});

/** "Run now": runs the thread's held start, or continues its paused turn,
    whatever the fleet reads. Never fails: `released: false` with the reason. */
const WsInfinitusReleaseThreadRpc = Rpc.make(INFINITUS_WS_METHODS.infinitusReleaseThread, {
  payload: InfinitusReleaseThreadInput,
  success: InfinitusReleaseThreadResult,
  error: EnvironmentAuthorizationError,
});

/** The threads whose turn a Claude usage limit stopped on this server (#648,
    #1627): the current list, then the whole list again on every change. The
    sidebar's "Limited" pill for a parked turn reads it; a failed one is on
    the thread shell too. */
const WsSubscribeInfinitusLimitStopsRpc = Rpc.make(
  INFINITUS_WS_METHODS.subscribeInfinitusLimitStops,
  {
    payload: Schema.Struct({}),
    success: InfinitusLimitStops,
    error: EnvironmentAuthorizationError,
    stream: true,
  },
);

/** A project's capture list (#433): the current list, then the whole list
    again after every change. */
const WsSubscribeCapturesRpc = Rpc.make(INFINITUS_WS_METHODS.subscribeCaptures, {
  payload: CapturesSubscribeInput,
  success: CaptureList,
  error: Schema.Union([CaptureStoreError, EnvironmentAuthorizationError]),
  stream: true,
});

/** One change to a project's capture list; the new list rides the
    subscription. */
const WsCapturesApplyRpc = Rpc.make(INFINITUS_WS_METHODS.capturesApply, {
  payload: CapturesApplyInput,
  success: CapturesApplyResult,
  error: Schema.Union([CaptureListFull, CaptureStoreError, EnvironmentAuthorizationError]),
});

/** Forwards one command from the manifest to the control socket. */
const WsInfinitusCommandRpc = Rpc.make(INFINITUS_WS_METHODS.infinitusCommand, {
  payload: InfinitusCommandInput,
  success: InfinitusCommandResult,
  error: Schema.Union([
    InfinitusUnavailable,
    InfinitusProtocolError,
    InfinitusCommandFailed,
    EnvironmentAuthorizationError,
  ]),
});

/** The fork's one secret-carrying path (#747): forwards `secret` on the
    control request line to a verb whose manifest entry says `stdin:
    "secret"`, and refuses everything else before the socket. Administrative
    scope; the reply is the verb's own, opaque. */
const WsInfinitusSecretRpc = Rpc.make(INFINITUS_WS_METHODS.infinitusSecret, {
  payload: InfinitusSecretInput,
  success: InfinitusSecretResult,
  error: Schema.Union([
    InfinitusSecretRefused,
    InfinitusUnavailable,
    InfinitusProtocolError,
    InfinitusCommandFailed,
    EnvironmentAuthorizationError,
  ]),
});

/** The fork's RPCs, spread into upstream's `WsRpcGroup`. */
export const INFINITUS_RPCS = [
  WsServerGetStatsRpc,
  WsSubscribeInfinitusRpc,
  WsInfinitusCommandRpc,
  WsInfinitusLaunchRpc,
  WsInfinitusSecretRpc,
  WsSubscribeInfinitusPairingRpc,
  WsInfinitusPairingDecideRpc,
  WsSubscribeInfinitusHoldsRpc,
  WsInfinitusReleaseThreadRpc,
  WsSubscribeInfinitusLimitStopsRpc,
  WsSubscribeCapturesRpc,
  WsCapturesApplyRpc,
] as const;
