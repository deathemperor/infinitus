import {
  AntigravitySettings,
  ClaudeSettings,
  CodexSettings,
<<<<<<< HEAD
  CursorSettings,
  GrokSettings,
  OmpSettings,
  OpenCodeSettings,
  PiSettings,
  ProviderDriverKind,
} from "@infinitus/contracts";
import type * as Schema from "effect/Schema";
import {
  AntigravityIcon,
  ClaudeAI,
  CursorIcon,
  GrokIcon,
  type Icon,
  OmpIcon,
  OpenAI,
  OpenCodeIcon,
  PiIcon,
} from "../Icons";
=======
  ProviderDriverKind,
} from "@infinitus/contracts";
import { acpRegistryClient } from "@infinitus/provider-acp-registry/client";
import { makeProviderClientRegistry } from "@infinitus/provider-core/client";
import { cursorClient } from "@infinitus/provider-cursor/client";
import { grokClient } from "@infinitus/provider-grok/client";
import { museClient } from "@infinitus/provider-muse/client";
import { openCodeClient } from "@infinitus/provider-opencode/client";
import { piClient } from "@infinitus/provider-pi/client";
>>>>>>> upstream-sync-43f8a8de1-upstream-renamed

/** The provider client definitions this web build ships, in presentation order. */
export const providerClients = makeProviderClientRegistry([
  {
    driverKind: ProviderDriverKind.make("codex"),
    label: "Codex",
    settingsSchema: CodexSettings,
  },
  {
    driverKind: ProviderDriverKind.make("claudeAgent"),
    label: "Claude",
    settingsSchema: ClaudeSettings,
  },
  cursorClient,
  grokClient,
  openCodeClient,
  {
<<<<<<< HEAD
    value: ProviderDriverKind.make("cursor"),
    label: "Cursor",
    icon: CursorIcon,
    badgeLabel: "Early Access",
    settingsSchema: CursorSettings,
  },
  {
    value: ProviderDriverKind.make("grok"),
    label: "Grok",
    icon: GrokIcon,
    badgeLabel: "Early Access",
    settingsSchema: GrokSettings,
  },
  {
    value: ProviderDriverKind.make("omp"),
    label: "Oh My Pi",
    icon: OmpIcon,
    badgeLabel: "Early Access",
    settingsSchema: OmpSettings,
  },
  {
    value: ProviderDriverKind.make("opencode"),
    label: "OpenCode",
    icon: OpenCodeIcon,
    settingsSchema: OpenCodeSettings,
  },
  {
    value: ProviderDriverKind.make("antigravity"),
=======
    driverKind: ProviderDriverKind.make("antigravity"),
>>>>>>> upstream-sync-43f8a8de1-upstream-renamed
    label: "Antigravity",
    settingsSchema: AntigravitySettings,
  },
<<<<<<< HEAD
  {
    value: ProviderDriverKind.make("pi"),
    label: "Pi",
    icon: PiIcon,
    badgeLabel: "Early Access",
    settingsSchema: PiSettings,
  },
];

const PROVIDER_CLIENT_DEFINITION_BY_VALUE: Partial<
  Record<ProviderDriverKind, ProviderClientDefinition>
> = Object.fromEntries(
  PROVIDER_CLIENT_DEFINITIONS.map((definition) => [definition.value, definition]),
);

export const DRIVER_OPTIONS = PROVIDER_CLIENT_DEFINITIONS;
export const DRIVER_OPTION_BY_VALUE = PROVIDER_CLIENT_DEFINITION_BY_VALUE;
export type DriverOption = ProviderClientDefinition;

/**
 * Look up the driver metadata for an instance's `driver` field. Accepts
 * Returns `undefined` for fork / unknown drivers so callers can decide how
 * to render them — typically by falling back to a generic card.
 */
export function getDriverOption(driver: ProviderDriverKind | undefined): DriverOption | undefined {
  if (driver === undefined) return undefined;
  return PROVIDER_CLIENT_DEFINITION_BY_VALUE[driver];
}
=======
  museClient,
  piClient,
  acpRegistryClient,
]);
>>>>>>> upstream-sync-43f8a8de1-upstream-renamed
