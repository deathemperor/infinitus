import type { ProviderInstanceConfig } from "@infinitus/contracts";

/** Whether the instance routes Claude through a proxy, which the advisor tool does not cross (#1232). */
function hasAnthropicBaseUrl(instance: ProviderInstanceConfig): boolean {
  return (instance.environment ?? []).some(
    (variable) => variable.name === "ANTHROPIC_BASE_URL" && variable.value.trim().length > 0,
  );
}

/** One line under a Claude instance's runtime settings when its advisor model cannot reach it. */
export function ClaudeAdvisorProxyNote({
  instance,
}: {
  readonly instance: ProviderInstanceConfig;
}) {
  if (instance.driver !== "claudeAgent" || !hasAnthropicBaseUrl(instance)) return null;
  return (
    <p className="text-xs text-muted-foreground">
      This instance routes through a proxy, which does not pass the advisor tool through.
    </p>
  );
}
