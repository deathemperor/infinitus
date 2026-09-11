import { useInfinitusEventToasts } from "../hooks/useInfinitusEventToasts";
import { useInfinitusPairingToasts } from "../hooks/useInfinitusPairingToasts";

/** Mounted once in the app shell: the Infinitus host's events, and the
    phones asking to pair (#710), as toasts. */
export function InfinitusEventToasts() {
  useInfinitusEventToasts();
  useInfinitusPairingToasts();
  return null;
}
