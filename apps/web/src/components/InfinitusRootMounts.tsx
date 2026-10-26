import { isElectron } from "../env";
import { CaptureGestureCoordinator } from "./captures/CaptureGestureCoordinator";
import { DeepLinkCoordinator } from "./deepLinks/DeepLinkCoordinator";
import { DesktopBadgeCoordinator } from "./desktop/DesktopBadgeCoordinator";
import { DesktopKeepAwakeCoordinator } from "./desktop/DesktopKeepAwakeCoordinator";
import { NotificationModeMigration } from "./desktop/NotificationModeMigration";
import { InfinitusEventToasts } from "./InfinitusEventToasts";
import { InfinitusPeerFleets } from "./InfinitusPeerFleets";
import { InfinitusSettingsSync } from "./InfinitusSettingsSync";

/**
 * The fork's headless coordinators, mounted once from the root route beside upstream's: deep links
 * (#270 D), notification-mode migration, dock badge and keep-awake
 * (`docs/internals/notifications.md`, `desktop-keep-awake.md`), capture gesture (#433), event
 * toasts, and, Electron only, peer fleets (#1545) and settings sync. None renders anything.
 */
export function InfinitusRootMounts({ authenticated }: { authenticated: boolean }) {
  return (
    <>
      {authenticated ? <DeepLinkCoordinator /> : null}
      <NotificationModeMigration />
      {authenticated ? <DesktopBadgeCoordinator /> : null}
      {authenticated ? <DesktopKeepAwakeCoordinator /> : null}
      <CaptureGestureCoordinator />
      {authenticated ? <InfinitusEventToasts /> : null}
      {authenticated && isElectron ? <InfinitusPeerFleets /> : null}
      {authenticated && isElectron ? <InfinitusSettingsSync /> : null}
    </>
  );
}
