import * as Schema from "effect/Schema";
import { PinIcon } from "lucide-react";
import { useId } from "react";

import { useLocalStorage } from "~/hooks/useLocalStorage";
import { cn } from "~/lib/utils";

import { Checkbox } from "../ui/checkbox";

/**
 * "Pin on create" for a new thread (#616): session priority mode holds
 * background threads for headroom and pinned threads never wait, so a thread
 * the user wants running from its first turn is pinned the moment the server
 * creates it. A per-browser preference, off by default; nothing on the server.
 */
export const PIN_AT_CREATION_KEY = "infinitus.pinAtCreation";

export function usePinAtCreation(): [boolean, (value: boolean) => void] {
  return useLocalStorage(PIN_AT_CREATION_KEY, false, Schema.Boolean);
}

export function PinAtCreationToggle({ className }: { readonly className?: string }) {
  const [pinAtCreation, setPinAtCreation] = usePinAtCreation();
  const id = useId();
  return (
    <label
      htmlFor={id}
      className={cn(
        "flex cursor-pointer items-center gap-2 text-muted-foreground text-xs",
        className,
      )}
    >
      <Checkbox
        id={id}
        checked={pinAtCreation}
        onCheckedChange={(checked) => setPinAtCreation(checked === true)}
      />
      <PinIcon className="size-3" aria-hidden="true" />
      <span>Pin on create — runs first when headroom is low</span>
    </label>
  );
}
