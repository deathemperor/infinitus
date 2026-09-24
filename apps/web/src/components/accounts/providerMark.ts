import { ClaudeAI, Gemini, type Icon, KiroIcon, OpenAI } from "../Icons";

/** The providers a fleet can report (native's `Provider`), by the name the
    snapshot carries. `other` and anything newer have no mark. */
const PROVIDER_PRESENTATION: Readonly<
  Record<string, { readonly label: string; readonly mark: Icon }>
> = {
  claude: { label: "Claude", mark: ClaudeAI },
  codex: { label: "Codex", mark: OpenAI },
  gemini: { label: "Gemini", mark: Gemini },
  kiro: { label: "Kiro", mark: KiroIcon },
};

/** What a fleet's provider looks like on the Accounts page: its logo, when
    there is one, and its name for the filter. */
export function fleetProvider(provider: string): {
  readonly label: string;
  readonly mark: Icon | null;
} {
  const known = PROVIDER_PRESENTATION[provider];
  if (known !== undefined) return known;
  return { label: provider.charAt(0).toUpperCase() + provider.slice(1), mark: null };
}
