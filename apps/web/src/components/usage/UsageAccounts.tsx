import { useAtomValue } from "@effect/atom-react";
import { infinitusCapabilityOf } from "@t3tools/client-runtime/state/infinitusAccounts";
import type { UsageAccountAttribution } from "@t3tools/contracts";
import { formatCount, formatPercent, formatTokens, formatUsd } from "@t3tools/shared/usageFormat";
import { CircleHelpIcon } from "lucide-react";

import { usePrimaryEnvironmentId } from "../../state/environments";
import { primaryServerConfigAtom } from "../../state/server";
import type { EnvironmentUsageStatus } from "../../state/usage";
import { Tooltip, TooltipPopup, TooltipTrigger } from "../ui/tooltip";

const UNATTRIBUTED_REASON =
  "Written within a swap's own second, or before the engine logged its first swap on this Mac.";

const totalTokens = (totals: UsageAccountAttribution["lines"][number]["totals"]): number =>
  totals.uncachedInputTokens +
  totals.cachedInputTokens +
  totals.cacheCreationTokens +
  totals.outputTokens;

/**
 * Claude spend split by the account that was active when each record was
 * written (#779), from the swap engine's own history read through the app.
 * Primary environment only, since the timeline is one Mac's; hidden unless
 * that server answered with one, so an app without the verb shows nothing
 * rather than an empty table.
 */
export function UsageAccountsSection({
  environments,
}: {
  readonly environments: ReadonlyArray<EnvironmentUsageStatus>;
}) {
  const environmentId = usePrimaryEnvironmentId();
  const capability = infinitusCapabilityOf(
    useAtomValue(primaryServerConfigAtom)?.environment.capabilities,
  );
  const accounts =
    capability === true && environmentId !== null
      ? environments.find((environment) => environment.environmentId === environmentId)?.summary
          ?.accounts
      : undefined;
  if (accounts === undefined) return null;

  const attributedUsd = accounts.lines.reduce((sum, line) => sum + line.costUsd, 0);
  const share = (costUsd: number) =>
    attributedUsd > 0 ? formatPercent(costUsd / attributedUsd, 0) : "—";
  const swaps = `${formatCount(accounts.switchesInWindow)} ${accounts.switchesInWindow === 1 ? "swap" : "swaps"} in this window`;

  const nothingToShow = accounts.lines.length === 0 && accounts.unattributed.records === 0;

  return (
    <section className="flex flex-col gap-2">
      <div className="flex items-baseline justify-between gap-3">
        <h2 className="text-sm font-medium text-foreground">By account</h2>
        <span className="text-xs text-muted-foreground">{swaps}</span>
      </div>
      {nothingToShow ? (
        <p className="text-sm text-muted-foreground">No Claude records in this window.</p>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full text-sm">
            <thead className="text-xs text-muted-foreground">
              <tr className="text-left">
                <th className="py-1 pr-3 font-medium">Account</th>
                <th className="py-1 pr-3 text-right font-medium">Cost</th>
                <th className="py-1 pr-3 text-right font-medium">Share</th>
                <th className="py-1 pr-3 text-right font-medium">Tokens</th>
                <th className="py-1 text-right font-medium">Records</th>
              </tr>
            </thead>
            <tbody>
              {accounts.lines.map((line) => (
                <tr key={line.email} className="border-t border-border/60">
                  <td className="py-1.5 pr-3">
                    <span className="text-foreground">{line.label}</span>
                    {line.number === undefined ? null : (
                      <span className="ml-1.5 text-xs text-muted-foreground">#{line.number}</span>
                    )}
                  </td>
                  <td className="py-1.5 pr-3 text-right tabular-nums">{formatUsd(line.costUsd)}</td>
                  <td className="py-1.5 pr-3 text-right tabular-nums text-muted-foreground">
                    {share(line.costUsd)}
                  </td>
                  <td className="py-1.5 pr-3 text-right tabular-nums">
                    {formatTokens(totalTokens(line.totals))}
                  </td>
                  <td className="py-1.5 text-right tabular-nums">{formatCount(line.records)}</td>
                </tr>
              ))}
              {accounts.unattributed.records === 0 ? null : (
                <tr className="border-t border-border/60 text-muted-foreground">
                  <td className="py-1.5 pr-3">
                    <span className="inline-flex items-center gap-1">
                      Unattributed
                      <Tooltip>
                        <TooltipTrigger
                          render={
                            <span
                              role="img"
                              aria-label={UNATTRIBUTED_REASON}
                              className="inline-flex"
                            />
                          }
                        >
                          <CircleHelpIcon className="size-3.5" aria-hidden />
                        </TooltipTrigger>
                        <TooltipPopup side="top">{UNATTRIBUTED_REASON}</TooltipPopup>
                      </Tooltip>
                    </span>
                  </td>
                  <td className="py-1.5 pr-3 text-right tabular-nums">
                    {formatUsd(accounts.unattributed.costUsd)}
                  </td>
                  <td className="py-1.5 pr-3 text-right">—</td>
                  <td className="py-1.5 pr-3 text-right tabular-nums">
                    {formatTokens(totalTokens(accounts.unattributed.totals))}
                  </td>
                  <td className="py-1.5 text-right tabular-nums">
                    {formatCount(accounts.unattributed.records)}
                  </td>
                </tr>
              )}
              {accounts.notClaude.records === 0 ? null : (
                <tr className="border-t border-border/60 text-muted-foreground">
                  <td className="py-1.5 pr-3">Other providers</td>
                  <td className="py-1.5 pr-3 text-right tabular-nums">
                    {formatUsd(accounts.notClaude.costUsd)}
                  </td>
                  <td className="py-1.5 pr-3 text-right">—</td>
                  <td className="py-1.5 pr-3 text-right">—</td>
                  <td className="py-1.5 text-right tabular-nums">
                    {formatCount(accounts.notClaude.records)}
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      )}
      <p className="text-xs text-muted-foreground">
        Estimate from transcript pricing and {accounts.basis}, not billing. Claude only; swaps
        before the engine's first logged switch on this Mac are not recorded.
      </p>
    </section>
  );
}
