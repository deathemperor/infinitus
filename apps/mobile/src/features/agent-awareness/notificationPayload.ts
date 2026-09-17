function dataFromNotificationResponse(response: unknown): Record<string, unknown> | null {
  if (typeof response !== "object" || response === null) {
    return null;
  }
  const notification = (response as { readonly notification?: unknown }).notification;
  if (typeof notification !== "object" || notification === null) {
    return null;
  }
  const request = (notification as { readonly request?: unknown }).request;
  if (typeof request !== "object" || request === null) {
    return null;
  }
  const content = (request as { readonly content?: unknown }).content;
  if (typeof content !== "object" || content === null) {
    return null;
  }
  const data = (content as { readonly data?: unknown }).data;
  if (typeof data === "object" && data !== null) {
    return data as Record<string, unknown>;
  }
  return pushPayloadFromRequest(request);
}

/** Infinitus (fork, #1375): expo-notifications on iOS fills `content.data`
    for a remote push from the payload's `body` key alone, and the relay
    sends its keys (`environmentId`, `threadId`, `deepLink`) at the top level
    beside `aps` — so `data` is empty there. The push trigger carries the
    whole `userInfo` as `payload`; that is the same keys, read second. */
export function pushPayloadFromRequest(request: unknown): Record<string, unknown> | null {
  if (typeof request !== "object" || request === null) {
    return null;
  }
  const trigger = (request as { readonly trigger?: unknown }).trigger;
  if (typeof trigger !== "object" || trigger === null) {
    return null;
  }
  if ((trigger as { readonly type?: unknown }).type !== "push") {
    return null;
  }
  const payload = (trigger as { readonly payload?: unknown }).payload;
  return typeof payload === "object" && payload !== null
    ? (payload as Record<string, unknown>)
    : null;
}

function identifierFromNotificationResponse(response: unknown): string | null {
  if (typeof response !== "object" || response === null) {
    return null;
  }
  const notification = (response as { readonly notification?: unknown }).notification;
  if (typeof notification !== "object" || notification === null) {
    return null;
  }
  const request = (notification as { readonly request?: unknown }).request;
  if (typeof request !== "object" || request === null) {
    return null;
  }
  const identifier = (request as { readonly identifier?: unknown }).identifier;
  return typeof identifier === "string" ? identifier : null;
}

function encodeThreadDeepLink(input: {
  readonly environmentId: string;
  readonly threadId: string;
}): string | null {
  if (input.environmentId.length === 0 || input.threadId.length === 0) {
    return null;
  }
  return `/threads/${encodeURIComponent(input.environmentId)}/${encodeURIComponent(input.threadId)}`;
}

function normalizeThreadDeepLink(value: string): string | null {
  if (
    value.trim() !== value ||
    value.startsWith("//") ||
    value.includes("?") ||
    value.includes("#")
  ) {
    return null;
  }

  const parts = value.split("/");
  if (parts.length !== 4 || parts[0] !== "" || parts[1] !== "threads") {
    return null;
  }

  try {
    return encodeThreadDeepLink({
      environmentId: decodeURIComponent(parts[2] ?? ""),
      threadId: decodeURIComponent(parts[3] ?? ""),
    });
  } catch {
    return null;
  }
}

/** Infinitus (fork, #1375): where an environment's account alert (a limit,
    a switch, a lapsed sign-in) lands — Settings › Accounts. The relay sends
    it as an ordinary push with this deep link and no thread. */
export const INFINITUS_ACCOUNTS_DEEP_LINK = "/settings/accounts";
/** Infinitus (fork, #1076): a lapsed sign-in's alert lands on the home
    screen, where the sign-in cards are. */
export const INFINITUS_HOME_DEEP_LINK = "/";

export function extractAgentNotificationDeepLink(response: unknown): string | null {
  const data = dataFromNotificationResponse(response);
  const deepLink = data?.deepLink;
  if (deepLink === INFINITUS_ACCOUNTS_DEEP_LINK || deepLink === INFINITUS_HOME_DEEP_LINK) {
    return deepLink;
  }
  if (typeof deepLink === "string") {
    const normalizedDeepLink = normalizeThreadDeepLink(deepLink);
    if (normalizedDeepLink) {
      return normalizedDeepLink;
    }
  }

  const environmentId = data?.environmentId;
  const threadId = data?.threadId;
  if (typeof environmentId === "string" && typeof threadId === "string") {
    return encodeThreadDeepLink({ environmentId, threadId });
  }
  return null;
}

export function routeAgentNotificationResponseOnce(input: {
  readonly handledResponseIds: Set<string>;
  readonly response: unknown;
  readonly navigate: (deepLink: string) => void;
}): void {
  const responseId = identifierFromNotificationResponse(input.response);
  if (responseId && input.handledResponseIds.has(responseId)) {
    return;
  }
  if (responseId) {
    input.handledResponseIds.add(responseId);
  }
  const deepLink = extractAgentNotificationDeepLink(input.response);
  if (deepLink) {
    input.navigate(deepLink);
  }
}
