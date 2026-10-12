import { InfinitusAlarmsBridge } from "./InfinitusAlarmsBridge";
import { InfinitusNotificationPresenter } from "./InfinitusNotificationPresenter";

/** The fork's headless bridges, mounted once from `App.tsx` beside
    upstream's hosts. Rules and traps: `docs/internals/phone-app-bridges.md`. */
export function InfinitusAppMounts() {
  return (
    <>
      <InfinitusAlarmsBridge />
      <InfinitusNotificationPresenter />
    </>
  );
}
