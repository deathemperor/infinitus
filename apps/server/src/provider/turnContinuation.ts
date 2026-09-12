/**
 * The one prompt that resumes a turn the server did not finish: the boot
 * continuation after a server update (serverRuntimeStartup) and the Claude
 * adapter's reconnect after a lost transport (#832) both send it.
 */
export const TURN_CONTINUATION_PROMPT = "Continue where you left off.";
