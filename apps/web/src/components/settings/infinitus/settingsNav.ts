import type { ComponentType } from "react";
import { BellIcon, CpuIcon, FilmIcon, GaugeIcon, InfinityIcon, UsersIcon } from "lucide-react";

import { useEnvironments } from "~/state/environments";
import type { SettingsPath } from "../settingsSearch";

/** The pages that only exist where a connected server drives an Infinitus app, with their nav icons. */
export const INFINITUS_SECTION_ICONS = {
  "/settings/menu-bar": InfinityIcon,
  "/settings/animations": FilmIcon,
  "/settings/priority": GaugeIcon,
  "/settings/team": UsersIcon,
  "/settings/notifications": BellIcon,
  "/settings/engines": CpuIcon,
} as const satisfies Partial<Record<SettingsPath, ComponentType<{ className?: string }>>>;

const INFINITUS_SETTINGS_PATHS: ReadonlySet<string> = new Set(Object.keys(INFINITUS_SECTION_ICONS));

/** Every page here drives one Infinitus app, never a settings scope, so none shows the scope picker. */
export const INFINITUS_DEVICE_ONLY_PATHS: ReadonlyArray<string> = [
  ...INFINITUS_SETTINGS_PATHS,
  "/settings/engines/activity",
];

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
