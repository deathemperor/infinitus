import { ORCHESTRATION_PROTOCOL_HEADER } from "@infinitus/contracts";
import { DESKTOP_DEV_URL_SCHEME, DESKTOP_URL_SCHEME } from "@infinitus/shared/desktopIdentity";

export const browserApiCorsAllowedMethods = ["GET", "POST", "OPTIONS"] as const;
export const browserApiCorsAllowedHeaders = [
  "authorization",
  "b3",
  "traceparent",
  "content-type",
  "dpop",
  ORCHESTRATION_PROTOCOL_HEADER,
] as const;

<<<<<<< HEAD
export const DESKTOP_RENDERER_ORIGINS = [
  `${DESKTOP_URL_SCHEME}://app`,
  `${DESKTOP_DEV_URL_SCHEME}://app`,
] as const;
=======
export const DESKTOP_RENDERER_ORIGINS = ["t3code://app", "t3code-dev://app"] as const;

/** MCP refuses every browser Origin with 403, so the browser CORS layer must not answer for it. */
export const MCP_HTTP_PATH = "/mcp";
>>>>>>> upstream-sync-d6419d92a0-upstream-renamed
