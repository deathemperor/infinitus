import { isProviderDriverKind } from "@infinitus/contracts";
import { acpRegistryClient } from "@infinitus/provider-acp-registry/client";
import { makeProviderClientRegistry } from "@infinitus/provider-core/client";
import { cursorClient } from "@infinitus/provider-cursor/client";
import { grokClient } from "@infinitus/provider-grok/client";
import { museClient } from "@infinitus/provider-muse/client";
import { openCodeClient } from "@infinitus/provider-opencode/client";
import { piClient } from "@infinitus/provider-pi/client";

const providerClients = makeProviderClientRegistry([
  cursorClient,
  grokClient,
  museClient,
  openCodeClient,
  piClient,
  acpRegistryClient,
]);

export function getProviderClient(driver: string | null | undefined) {
  return isProviderDriverKind(driver) ? providerClients.get(driver) : undefined;
}
