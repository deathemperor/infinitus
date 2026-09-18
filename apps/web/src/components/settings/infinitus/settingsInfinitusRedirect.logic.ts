/** Where a `/settings/infinitus[/…]` path lands now. The fork's pages were a
    Settings group by that name until 2026-09-18; the whole app is Infinitus,
    so they are top-level pages and the old paths — an older menu bar app's ⌘,
    and its onboarding card, a bookmark — redirect here. */
const RENAMED: Readonly<Record<string, string>> = {
  "": "/settings/menu-bar",
  animations: "/settings/animations",
  sessions: "/settings/priority",
  team: "/settings/team",
  notifications: "/settings/notifications",
  devices: "/settings/devices",
  engines: "/settings/engines",
  "engines/activity": "/settings/engines/activity",
};

export function redirectedInfinitusSettingsPath(splat: string | undefined): string {
  const rest = (splat ?? "").replace(/^\/+|\/+$/g, "");
  return RENAMED[rest] ?? "/settings/menu-bar";
}
