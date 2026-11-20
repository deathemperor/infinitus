import type { ServerEventLoopStall } from "@infinitus/contracts";
<<<<<<< HEAD
import { PRODUCT_NAME } from "@infinitus/shared/productName";
=======
import { mFallback, msg } from "gt-i18n";
import type { MFunctionType } from "gt-i18n/types";
>>>>>>> upstream-sync-f2d4df0367-upstream-renamed

export interface HostFreezeNotice {
  readonly title: string;
  readonly description: string;
}

/**
 * Says why a host stopped answering, from the recent stall it reports on
 * connect. Web shows it as a toast, mobile in the environment's connection row.
 */
export function hostFreezeNotice(
  hostLabel: string,
  stall: ServerEventLoopStall | undefined,
  resolve: MFunctionType = mFallback,
): HostFreezeNotice | null {
  if (stall === undefined) return null;
  const { loadAverage, cpuCount } = stall;
  return {
    title: resolve(
      msg("{host} froze for {seconds}s", {
        host: hostLabel,
        seconds: Math.round(stall.durationMs / 1000),
      }),
    ),
    description:
      loadAverage !== undefined && loadAverage > cpuCount
<<<<<<< HEAD
        ? `Its CPU is overloaded (load ${Math.round(loadAverage)} on ${cpuCount} cores).`
        : `${PRODUCT_NAME} on ${hostLabel} was too busy to answer.`,
=======
        ? resolve(
            msg("Its CPU is overloaded (load {load} on {cpuCount} cores).", {
              load: Math.round(loadAverage),
              cpuCount,
            }),
          )
        : resolve(msg("T3 Code on {host} was too busy to answer.", { host: hostLabel })),
>>>>>>> upstream-sync-f2d4df0367-upstream-renamed
  };
}
