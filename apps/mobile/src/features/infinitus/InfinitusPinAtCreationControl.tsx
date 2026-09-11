import { useAtomSet, useAtomValue } from "@effect/atom-react";
import type { EnvironmentId } from "@t3tools/contracts";

import { ComposerInlineControl } from "../../components/ComposerToolbar";
import { mobilePreferencesAtom, updateMobilePreferencesAtom } from "../../state/preferences";
import { environmentServerConfigsAtom } from "../../state/server";
import { PIN_AT_CREATION_HINT, pinAtCreationEnabled } from "./pinAtCreation.logic";

/**
 * The new-task composer's "Pin" pill (#742, the web's "Pin on create" of
 * #753): session priority mode holds background threads for headroom and
 * pinned threads never wait, so a task the user wants running from its first
 * turn is pinned the moment the server creates it. A per-phone preference,
 * off by default; only shown for a project whose server pins threads.
 */
export function InfinitusPinAtCreationControl(props: {
  readonly environmentId: EnvironmentId | null;
  readonly disabled?: boolean;
}) {
  const preferences = useAtomValue(mobilePreferencesAtom);
  const savePreferences = useAtomSet(updateMobilePreferencesAtom);
  const configs = useAtomValue(environmentServerConfigsAtom);
  const supported =
    props.environmentId !== null &&
    configs.get(props.environmentId)?.environment.capabilities.threadPinning === true;
  if (!supported) return null;
  const on = pinAtCreationEnabled(preferences);
  return (
    <ComposerInlineControl
      accessibilityHint={PIN_AT_CREATION_HINT}
      accessibilityLabel={`Pin on create: ${on ? "on" : "off"}`}
      disabled={props.disabled}
      emphasized={on}
      icon={on ? { ios: "pin.fill", android: "push_pin" } : { ios: "pin", android: "push_pin" }}
      label="Pin"
      onPress={() => savePreferences({ infinitusPinAtCreation: !on })}
      showChevron={false}
    />
  );
}
