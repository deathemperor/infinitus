import { useInfinitusEventToasts } from "../hooks/useInfinitusEventToasts";

/** Mounted once in the app shell: the Infinitus host's events as toasts. */
export function InfinitusEventToasts() {
  useInfinitusEventToasts();
  return null;
}
