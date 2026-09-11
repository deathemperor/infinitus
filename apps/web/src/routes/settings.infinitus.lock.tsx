import { createFileRoute } from "@tanstack/react-router";

import { InfinitusLockPanel } from "../components/settings/infinitus/InfinitusLockPanel";

/** The Mac's biometric lock as a web page (#747): on/off, the re-lock choice,
    Lock now / Unlock over the control socket's lock verbs. */
function SettingsInfinitusLockRoute() {
  return <InfinitusLockPanel />;
}

export const Route = createFileRoute("/settings/infinitus/lock")({
  component: SettingsInfinitusLockRoute,
});
