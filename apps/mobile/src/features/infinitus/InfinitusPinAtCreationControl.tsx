import { useAtomValue } from "@effect/atom-react";
import type { EnvironmentId } from "@infinitus/contracts";

import { ComposerInlineControl } from "../../components/ComposerToolbar";
import { mobilePreferencesAtom, saveMobilePreferences } from "../../state/preferences";
import { useAtomCommand } from "../../state/use-atom-command";
import { environmentServerConfigsAtom } from "../../state/server";
import { PIN_AT_CREATION_HINT, pinAtCreationEnabled } from "./pinAtCreation.logic";

/**
 * The new-task composer's "Pin" pill (#742): session priority mode holds background
 * threads for headroom and pinned ones never wait. A per-phone preference, off by
 * default; shown only for a project whose server pins threads.
 */
export function InfinitusPinAtCreationControl(props: {
  readonly environmentId: EnvironmentId | null;
  readonly disabled?: boolean;
}) {
  const preferences = useAtomValue(mobilePreferencesAtom);
  const savePreferences = useAtomCommand(saveMobilePreferences);
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
      onPress={() => void savePreferences({ infinitusPinAtCreation: !on })}
      showChevron={false}
    />
  );
}
