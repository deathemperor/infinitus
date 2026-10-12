import type { ComponentType } from "react";
import {
  BellIcon,
  CpuIcon,
  GaugeIcon,
  InfinityIcon,
  SmartphoneIcon,
  SparklesIcon,
  UsersIcon,
} from "lucide-react";

import { useEnvironments } from "~/state/environments";
import type { SettingsPath } from "../settingsSearch";

/** The pages that only exist where a connected server drives an Infinitus app, with their nav icons. */
export const INFINITUS_SECTION_ICONS = {
  "/settings/menu-bar": InfinityIcon,
  "/settings/animations": SparklesIcon,
  "/settings/priority": GaugeIcon,
  "/settings/team": UsersIcon,
  "/settings/notifications": BellIcon,
  "/settings/devices": SmartphoneIcon,
  "/settings/engines": CpuIcon,
} as const satisfies Partial<Record<SettingsPath, ComponentType<{ className?: string }>>>;

const INFINITUS_SETTINGS_PATHS: ReadonlySet<string> = new Set(Object.keys(INFINITUS_SECTION_ICONS));

/**
 * The nav filter that hides the menu bar app's pages when no connected
 * environment runs it. One connected Infinitus is enough: the pages read the
 * primary environment but the nav only decides whether they lead anywhere at all.
 */
export function useInfinitusSectionFilter(): (item: { readonly to: SettingsPath }) => boolean {
  const { environments } = useEnvironments();
  const infinitusSupported = environments.some(
    (environment) => environment.serverConfig?.environment.capabilities.infinitus === true,
  );
  return (item) => infinitusSupported || !INFINITUS_SETTINGS_PATHS.has(item.to);
}
