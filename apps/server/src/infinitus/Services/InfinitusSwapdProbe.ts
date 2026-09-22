import type { InfinitusSnapshot } from "@infinitus/contracts/infinitus";
import { HostProcessEnvironment, HostProcessPlatform } from "@infinitus/shared/hostProcess";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Schema from "effect/Schema";
import * as NodeOS from "node:os";
import { ProcessRunner } from "../../processRunner.ts";

const Window = Schema.Struct({
  kind: Schema.String,
  name: Schema.optionalKey(Schema.String),
  pct: Schema.Finite,
});
const List = Schema.Struct({
  schemaVersion: Schema.Literal(1),
  providers: Schema.Array(
    Schema.Struct({
      provider: Schema.String,
      activeSlot: Schema.optionalKey(Schema.Finite),
      accounts: Schema.Array(
        Schema.Struct({
          slot: Schema.Finite,
          email: Schema.String,
          alias: Schema.optionalKey(Schema.String),
          active: Schema.Boolean,
          disabled: Schema.Boolean,
          usageStatus: Schema.String,
          fetchedAt: Schema.optionalKey(Schema.String),
          windows: Schema.Array(Window),
        }),
      ),
    }),
  ),
});
const decodeList = Schema.decodeUnknownEffect(Schema.fromJsonString(List));
const unavailable: InfinitusSnapshot = { available: false, fleets: [], commands: [] };

/** Only the resume worker uses this daemon bridge. Native commands and
 * UI availability still belong to the menu bar's control socket. */
export class InfinitusSwapdProbe extends Context.Service<
  InfinitusSwapdProbe,
  {
    readonly snapshot: Effect.Effect<InfinitusSnapshot>;
    /** Report the account that was refused; the daemon owns switching policy. */
    readonly reportLimit: (account: string, resetsAt: string | null) => Effect.Effect<void>;
  }
>()("t3/infinitus/Services/InfinitusSwapdProbe") {}

export const InfinitusSwapdProbeLive = Layer.effect(
  InfinitusSwapdProbe,
  Effect.gen(function* () {
    const runner = yield* ProcessRunner;
    const platform = yield* HostProcessPlatform;
    const environment = yield* HostProcessEnvironment;
    const binary =
      environment.INFINITUS_SWAPD_CLI ??
      `${NodeOS.homedir()}/Library/Application Support/Infinitus/engines/swapd`;
    const snapshot = Effect.gen(function* () {
      if (platform !== "darwin" || binary === "") return unavailable;
      const result = yield* runner.run({
        command: binary,
        args: ["--json", "--provider", "claude", "list"],
        timeout: "10 seconds",
        maxOutputBytes: 1024 * 1024,
      });
      if (
        result.code !== 0 ||
        result.timedOut ||
        result.stdoutTruncated ||
        result.stdoutInvalidUtf8
      )
        return unavailable;
      const list = yield* decodeList(result.stdout);
      return {
        available: true,
        commands: [],
        fleets: list.providers.map((provider) => ({
          key: `swapd/${provider.provider}`,
          engineID: "swapd",
          provider: provider.provider,
          capabilities: [],
          accounts: provider.accounts.map((account) => ({
            number: account.slot,
            email: account.email,
            ...(account.alias === undefined ? {} : { alias: account.alias }),
            // Unreadable credentials and undated cache entries cannot prove
            // that a replacement account is safe to resume on.
            active: account.active && !account.disabled && account.slot === provider.activeSlot,
            disabled: account.disabled,
            isOrganization: false,
            usageStatus:
              account.fetchedAt !== undefined && Number.isFinite(Date.parse(account.fetchedAt))
                ? account.usageStatus
                : "unknown",
            ...(account.fetchedAt === undefined ? {} : { usageFetchedAt: account.fetchedAt }),
            usage: {
              ...Object.fromEntries(
                account.windows.flatMap((window) =>
                  window.kind === "5h"
                    ? [["fiveHour", window]]
                    : window.kind === "7d"
                      ? [["sevenDay", window]]
                      : [],
                ),
              ),
              scoped: account.windows.filter((window) => window.kind === "scoped"),
            },
          })),
        })),
      } satisfies InfinitusSnapshot;
    }).pipe(Effect.catch(() => Effect.succeed(unavailable)));
    const reportLimit = Effect.fn("InfinitusSwapdProbe.reportLimit")(
      function* (account: string, resetsAt: string | null) {
        if (platform !== "darwin" || binary === "") return;
        const result = yield* runner.run({
          command: binary,
          args: [
            "--json",
            "--provider",
            "claude",
            "limit-hit",
            account,
            ...(resetsAt === null ? [] : ["--resets-at", resetsAt]),
          ],
          timeout: "10 seconds",
          maxOutputBytes: 1024 * 1024,
        });
        if (result.code !== 0 || result.timedOut) {
          yield* Effect.logWarning("infinitus.swapd.limit-report-failed", {
            code: result.code,
            timedOut: result.timedOut,
          });
        }
      },
      // Older or unavailable engines must not prevent watching for a switch.
      Effect.catch(() => Effect.logWarning("infinitus.swapd.limit-report-failed")),
    );
    return { snapshot, reportLimit };
  }),
);
