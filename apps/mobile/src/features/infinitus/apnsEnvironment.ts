import { File, Paths } from "expo-file-system";

import { type ApnsEnvironment, apnsEnvironmentFromProfile } from "./apnsEnvironment.logic";

let resolved: Promise<ApnsEnvironment> | null = null;

/** The APNs environment of this install, from `embedded.mobileprovision` in
    the bundle; read once. Falls back to `__DEV__` if the read itself fails. */
export function resolveApnsEnvironment(): Promise<ApnsEnvironment> {
  resolved ??= (async () => {
    try {
      const file = new File(Paths.bundle, "embedded.mobileprovision");
      if (!file.exists) return apnsEnvironmentFromProfile(null);
      const bytes = await file.bytes();
      let text = "";
      for (let i = 0; i < bytes.length; i += 1) text += String.fromCharCode(bytes[i] ?? 0);
      return apnsEnvironmentFromProfile(text);
    } catch {
      return __DEV__ ? "sandbox" : "production";
    }
  })();
  return resolved;
}
