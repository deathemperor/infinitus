import type { ComponentType } from "react";
import { BellIcon, CpuIcon, GaugeIcon, InfinityIcon, SparklesIcon, UsersIcon } from "lucide-react";

import { useEnvironments } from "~/state/environments";
import type { SettingsPath } from "../settingsSearch";

/** The pages that only exist where a connected server drives an Infinitus app, with their nav icons. */
export const INFINITUS_SECTION_ICONS = {
  "/settings/menu-bar": InfinityIcon,
  "/settings/animations": SparklesIcon,
  "/settings/priority": GaugeIcon,
  "/settings/team": UsersIcon,
  "/settings/notifications": BellIcon,
  "/settings/engines": CpuIcon,
} as const satisfies Partial<Record<SettingsPath, ComponentType<{ className?: string }>>>;

const INFINITUS_SETTINGS_PATHS: ReadonlySet<string> = new Set(Object.keys(INFINITUS_SECTION_ICONS));

/**
 * The nav groups minus the menu bar app's pages, and any group they leave empty, when no
 * connected environment runs it. One connected Infinitus is enough: the pages read the
 * primary environment but the nav only decides whether they lead anywhere at all.
 */
export function useInfinitusNavGroups<
  Group extends { readonly paths: ReadonlyArray<SettingsPath> },
>(groups: ReadonlyArray<Group>): ReadonlyArray<Group> {
  const { environments } = useEnvironments();
  const infinitusSupported = environments.some(
    (environment) => environment.serverConfig?.environment.capabilities.infinitus === true,
  );
  if (infinitusSupported) return groups;
  return groups
    .map((group) => ({
      ...group,
      paths: group.paths.filter((to) => !INFINITUS_SETTINGS_PATHS.has(to)),
    }))
    .filter((group) => group.paths.length > 0);
}
