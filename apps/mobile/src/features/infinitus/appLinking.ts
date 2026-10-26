import * as Linking from "expo-linking";

import { teamJoinLinkCode, UNIVERSAL_LINK_HOST } from "../team/team.logic";

/** Fork (#1313): a team invite (`https://infinitus.run/join#<code>`) opens
    Settings › Team with the code; any other URL passes through untouched. */
const rewriteIncomingUrl = (url: string | null): string | null => {
  if (url === null) return null;
  const teamCode = teamJoinLinkCode(url);
  return teamCode === null
    ? url
    : Linking.createURL("settings/team", { queryParams: { code: teamCode } });
};

/**
 * The fork's additions to `App.tsx`'s `appLinking`, spread into it: the
 * site's universal link as a prefix, and the two listeners that rewrite an
 * incoming URL before React Navigation routes it.
 */
export const INFINITUS_LINK_PREFIXES: ReadonlyArray<string> = [`https://${UNIVERSAL_LINK_HOST}`];

export const infinitusLinkingListeners = {
  getInitialURL: async () => rewriteIncomingUrl(await Linking.getInitialURL()),
  subscribe: (listener: (url: string) => void) => {
    const subscription = Linking.addEventListener("url", ({ url }) => {
      const rewritten = rewriteIncomingUrl(url);
      if (rewritten !== null) listener(rewritten);
    });
    return () => subscription.remove();
  },
};
