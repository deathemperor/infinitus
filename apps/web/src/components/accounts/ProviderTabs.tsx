import { ALL_PROVIDERS } from "@infinitus/client-runtime/state/infinitusAccounts";

import { Badge } from "../ui/badge";
import { Button } from "../ui/button";
import { fleetProvider } from "./providerMark";

/**
 * One machine's accounts split by provider, each with its account count, so a
 * machine running Claude and Codex fleets can show one at a time. Only drawn
 * when there is more than one provider to tell apart.
 */
export function ProviderTabs({
  providers,
  selected,
  onSelect,
}: {
  readonly providers: ReadonlyArray<{ readonly provider: string; readonly accounts: number }>;
  /** `all`, or one provider's name as the snapshot carries it. */
  readonly selected: string;
  readonly onSelect: (provider: string) => void;
}) {
  const total = providers.reduce((sum, entry) => sum + entry.accounts, 0);
  const tabs = [
    { provider: ALL_PROVIDERS, label: "All", accounts: total, Mark: null },
    ...providers.map((entry) => {
      const presentation = fleetProvider(entry.provider);
      return { ...entry, label: presentation.label, Mark: presentation.mark };
    }),
  ];
  return (
    <div className="flex flex-wrap items-center gap-1" role="radiogroup" aria-label="Provider">
      {tabs.map(({ provider, label, accounts, Mark }) => (
        <Button
          key={provider}
          size="sm"
          variant={provider === selected ? "secondary" : "ghost"}
          role="radio"
          aria-checked={provider === selected}
          onClick={() => onSelect(provider)}
        >
          {Mark === null ? null : <Mark aria-hidden />}
          {label}
          <Badge size="sm" variant="outline">
            {accounts}
          </Badge>
        </Button>
      ))}
    </div>
  );
}
