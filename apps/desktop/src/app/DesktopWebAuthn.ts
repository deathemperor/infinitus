import type { JoinPath } from "./DesktopStatePaths.ts";

/**
 * Passkeys in the preview browser need Electron's Touch ID authenticator
 * (`app.configureWebAuthn`, before `ready`), and Electron refuses the keychain
 * access group it is given unless the signed `keychain-access-groups`
 * entitlement carries the same value. The build writes the group it signed
 * into the staged package.json (scripts/build-desktop-artifact.ts), so a dev
 * or unsigned build — which has no such entitlement — configures nothing and
 * keeps reporting no platform authenticator instead of failing every request.
 */
export function resolveEarlyWebAuthnKeychainAccessGroup(input: {
  readonly isPackaged: boolean;
  readonly appPath: string;
  readonly joinPath: JoinPath;
  readonly readFileString: (path: string) => string;
}): string | null {
  if (!input.isPackaged) {
    return null;
  }
  let group: unknown;
  try {
    const metadata: unknown = JSON.parse(
      input.readFileString(input.joinPath(input.appPath, "package.json")),
    );
    group =
      typeof metadata === "object" && metadata !== null && "webauthnKeychainAccessGroup" in metadata
        ? metadata.webauthnKeychainAccessGroup
        : undefined;
  } catch {
    return null;
  }
  const trimmed = typeof group === "string" ? group.trim() : "";
  return trimmed.length > 0 ? trimmed : null;
}
