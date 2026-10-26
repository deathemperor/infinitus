// The command palette's "Jump to next waiting thread" action and the `thread.nextAttention` key
// share one resolver, which lives in the sidebar because only it holds the rendered order and
// statuses (#270 C). The palette asks over a window event, like commandPaletteBus, so neither
// component owns the other's state.
const NEXT_ATTENTION_THREAD_EVENT = "infinitus:next-attention-thread";

export function requestNextAttentionThread(): void {
  window.dispatchEvent(new CustomEvent(NEXT_ATTENTION_THREAD_EVENT));
}

export function onNextAttentionThreadRequest(listener: () => void): () => void {
  window.addEventListener(NEXT_ATTENTION_THREAD_EVENT, listener);
  return () => window.removeEventListener(NEXT_ATTENTION_THREAD_EVENT, listener);
}
