import {
  AntigravitySettings,
  ClaudeSettings,
  CodexSettings,
  ProviderDriverKind,
} from "@infinitus/contracts";
import { acpRegistryClient } from "@infinitus/provider-acp-registry/client";
import { makeProviderClientRegistry } from "@infinitus/provider-core/client";
import { cursorClient } from "@infinitus/provider-cursor/client";
import { fxClient } from "@infinitus/provider-fx/client";
import { grokClient } from "@infinitus/provider-grok/client";
import { museClient } from "@infinitus/provider-muse/client";
import { openCodeClient } from "@infinitus/provider-opencode/client";
import { piClient } from "@infinitus/provider-pi/client";

export const providerClients = makeProviderClientRegistry([
  {
    driverKind: ProviderDriverKind.make("codex"),
    label: "Codex",
    acpRegistryAgentIds: ["codex-acp"],
    settingsSchema: CodexSettings,
  },
  {
    driverKind: ProviderDriverKind.make("claudeAgent"),
    label: "Claude",
    acpRegistryAgentIds: ["claude-acp"],
    settingsSchema: ClaudeSettings,
  },
  cursorClient,
  grokClient,
  fxClient,
  openCodeClient,
  {
    driverKind: ProviderDriverKind.make("antigravity"),
    label: "Antigravity",
    acpRegistryAgentIds: ["antigravity-acp"],
    settingsSchema: AntigravitySettings,
  },
  museClient,
  piClient,
  acpRegistryClient,
]);
