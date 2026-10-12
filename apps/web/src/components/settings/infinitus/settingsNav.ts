import {
  BellIcon,
  CpuIcon,
  InfinityIcon,
  SmartphoneIcon,
  SparklesIcon,
  UsersIcon,
} from "lucide-react";
import type { ComponentType } from "react";

import { useInfinitusSupported } from "~/hooks/useInfinitusSupported";
import type { SettingsPath } from "../settingsSearch";

/** The pages that only exist where a connected server drives an Infinitus app. */
const INFINITUS_SETTINGS_PATHS = [
  "/settings/menu-bar",
  "/settings/animations",
  "/settings/team",
  "/settings/notifications",
  "/settings/devices",
  "/settings/engines",
] as const satisfies ReadonlyArray<SettingsPath>;

type InfinitusSettingsPath = (typeof INFINITUS_SETTINGS_PATHS)[number];

/** The settings nav's icon per Infinitus page, spread into upstream's table. */
export const INFINITUS_SETTINGS_SECTION_ICONS: Readonly<
  Record<InfinitusSettingsPath, ComponentType<{ className?: string }>>
> = {
  "/settings/menu-bar": InfinityIcon,
  "/settings/animations": SparklesIcon,
  "/settings/team": UsersIcon,
  "/settings/notifications": BellIcon,
  "/settings/devices": SmartphoneIcon,
  "/settings/engines": CpuIcon,
};

const INFINITUS_SETTINGS_PATH_SET: ReadonlySet<SettingsPath> = new Set(INFINITUS_SETTINGS_PATHS);

/**
 * Upstream's nav items, minus the menu bar app's pages when no connected
 * environment runs it. Wraps upstream's own filter so the registration in
 * `SettingsSidebarNav.tsx` stays one call.
 */
export function useInfinitusSettingsNavItems<T extends { readonly to: SettingsPath }>(
  items: ReadonlyArray<T>,
): ReadonlyArray<T> {
  const supported = useInfinitusSupported();
  return supported ? items : items.filter((item) => !INFINITUS_SETTINGS_PATH_SET.has(item.to));
}
