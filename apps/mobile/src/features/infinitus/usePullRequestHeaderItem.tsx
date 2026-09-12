import { useAtomValue } from "@effect/atom-react";
import type { EnvironmentThreadShell } from "@t3tools/client-runtime/state/models";
import type { PullRequestRef } from "@t3tools/contracts";
import { resolveThreadCurrentPullRequestLink } from "@t3tools/shared/threadPullRequests";
import * as Cause from "effect/Cause";
import { useMemo } from "react";
import { Alert } from "react-native";

import { tryOpenExternalUrl } from "../../lib/openExternalUrl";
import { environmentServerConfigsAtom } from "../../state/server";
import { resolveThreadPrSource } from "../../state/thread-pr-presentation";
import { threadEnvironment } from "../../state/threads";
import { useAtomCommand } from "../../state/use-atom-command";
import {
  babysitLabel,
  prChecksUrl,
  prHeaderMenuItems,
  prPhaseLabel,
  type PrPhaseInput,
} from "./prHeader.logic";
import { runPullRequestAction } from "./pullRequestActions";
import { PR_ICON, type ThreadMenuPullRequest } from "./threadHeaderMenu.logic";

export interface PullRequestHeaderItem {
  /** The thread header menu's pull request part, or null while the thread
      has no pull request to show. */
  readonly menu: ThreadMenuPullRequest | null;
  /** Changes whenever the menu's content does; the native header's option
      factories are stabilised, so ThreadRouteScreen feeds this to
      `optionsVersion` (a menu built from a later snapshot would otherwise
      keep its first, emptier shape). */
  readonly version: string;
}

const NO_ITEM: PullRequestHeaderItem = { menu: null, version: "" };

/**
 * The thread header menu's pull request part (#269 F, folded into one
 * button with the side question and usage by #941): the PR's number as the
 * button's label, its phase ("Ready for review", "Checks failing", …) as the first,
 * inert line, then "Open pull request", "View checks" (GitHub) and, for a
 * draft on a server that runs PR actions, "Mark ready for review" through
 * `pullRequests.runAction` — the web PR panel's route; the server re-syncs
 * the link afterwards, so the phase follows on its own. The phase reads the
 * linked snapshot the server pushes with the thread; a thread with only the
 * legacy branch reference (no link) gets the number and "Open pull request".
 */
export function usePullRequestHeaderItem(
  thread: EnvironmentThreadShell | null,
): PullRequestHeaderItem {
  const configs = useAtomValue(environmentServerConfigsAtom);
  const capabilities =
    thread === null ? undefined : configs.get(thread.environmentId)?.environment.capabilities;
  const supportsLinks = capabilities?.threadPullRequests === true;
  const supportsActions = capabilities?.pullRequests === true;
  // Fork (#269 A): babysit needs the fork's server; the menu item's own gate
  // (an open PR, or already on) lives in `prHeaderMenuItems`.
  const supportsBabysit = capabilities?.infinitus === true;
  const runAction = useAtomCommand(runPullRequestAction, { reportFailure: false });
  const updateMetadata = useAtomCommand(threadEnvironment.updateMetadata, {
    reportFailure: false,
  });

  return useMemo<PullRequestHeaderItem>(() => {
    if (thread === null) return NO_ITEM;
    const { linkedPresentation, pullRequestRef } = resolveThreadPrSource(thread, {
      threadPullRequests: supportsLinks,
    });
    const link =
      linkedPresentation === null ? null : resolveThreadCurrentPullRequestLink(thread.pullRequests);
    const number = link?.number ?? pullRequestRef?.number;
    const url = link?.url ?? pullRequestRef?.url;
    if (number === undefined || url === undefined) return NO_ITEM;
    const snapshot = link?.snapshot ?? null;
    const phase: PrPhaseInput = {
      state: linkedPresentation?.state ?? null,
      isDraft: linkedPresentation?.isDraft,
      checksState: snapshot?.checksState,
      reviewDecision: snapshot?.reviewDecision,
      mergeability: snapshot?.mergeability,
    };
    const ref: PullRequestRef | null =
      link !== null
        ? {
            projectId: thread.projectId,
            host: link.host,
            repository: link.repository,
            number: link.number,
          }
        : pullRequestRef;
    const checksUrl = prChecksUrl(url);
    const items = prHeaderMenuItems({
      pr: phase,
      checksUrl,
      // A stack's badge names its top PR; stack actions need fields the phone
      // does not send, so a stack stays read-only here.
      canRunActions: supportsActions && ref !== null && linkedPresentation?.kind !== "stack",
      babysit: supportsBabysit ? { state: thread.babysit ?? null } : null,
    });
    const phaseLabel = prPhaseLabel(phase);
    const status = linkedPresentation?.accessibilityLabel ?? `#${number} pull request`;
    const babysitting = babysitLabel(thread.babysit);
    const setBabysit = (on: boolean): void => {
      void updateMetadata({
        environmentId: thread.environmentId,
        input: { threadId: thread.id, babysit: on },
      }).then((result) => {
        if (result._tag === "Failure") {
          const error = Cause.squash(result.cause);
          Alert.alert(
            on ? "Could not babysit" : "Still babysitting",
            error instanceof Error ? error.message : String(error),
          );
        }
      });
    };
    const run = (action: (typeof items)[number]["action"]): void => {
      switch (action) {
        case "open":
          void tryOpenExternalUrl(url, "pull-request");
          return;
        case "checks":
          if (checksUrl !== null) void tryOpenExternalUrl(checksUrl, "pull-request");
          return;
        case "ready":
          if (ref === null) return;
          void runAction({
            environmentId: thread.environmentId,
            input: { ...ref, action: "ready" },
          }).then((result) => {
            if (result._tag === "Failure") {
              const error = Cause.squash(result.cause);
              Alert.alert("Still a draft", error instanceof Error ? error.message : String(error));
            }
          });
          return;
        case "babysit-on":
          setBabysit(true);
          return;
        case "babysit-off":
          setBabysit(false);
          return;
      }
    };
    return {
      menu: {
        number,
        status,
        actions: [
          {
            id: "phase",
            label: phaseLabel,
            description: babysitting ?? status,
            icon: PR_ICON,
            disabled: true,
            onPress: (): void => {},
          },
          ...items.map((item) => ({
            id: item.action,
            label: item.label,
            description: item.description,
            icon: item.icon,
            onPress: (): void => run(item.action),
          })),
        ],
      },
      version: [number, url, phaseLabel, babysitting, ...items.map((item) => item.label)].join(":"),
    };
  }, [runAction, supportsActions, supportsBabysit, supportsLinks, thread, updateMetadata]);
}
