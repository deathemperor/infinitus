/**
 * Fork (#1088): a Claude instance that routes through an Anthropic-compatible
 * proxy carries `ANTHROPIC_BASE_URL` on its environment (`applyProxyDraft`).
 * What reaches the proxy is a plain Anthropic request, so anything the manifest
 * expresses in Anthropic's own wire syntax — the bracket model suffixes,
 * `claude-opus-5[1m]` — has to be left off: CLIProxyAPI answers 400 "unknown
 * provider for model claude-opus-5[1m]", and a proxy that tolerates it still
 * routes on the bare slug.
 */
const PROXY_BASE_URL_VARIABLE = "ANTHROPIC_BASE_URL";

/** Whether the environment a Claude CLI is spawned with points at a proxy. */
export function isProxiedClaudeEnvironment(environment: NodeJS.ProcessEnv | undefined): boolean {
  return (environment?.[PROXY_BASE_URL_VARIABLE] ?? "").trim() !== "";
}
