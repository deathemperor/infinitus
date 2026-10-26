export interface IncomingSharePresentationState {
  readonly presentedShareId: string | null;
  readonly dismissedShareId: string | null;
}

export interface IncomingSharePresentationTransition {
  readonly state: IncomingSharePresentationState;
  readonly shareIdToPresent: string | null;
  /**
   * The share whose sheet just closed without importing it. Closing the sheet
   * is the user's only way to decline a share: nothing else lists the inbox,
   * so a declined item that stayed durable would reopen the same sheet on
   * every cold launch (an in-memory dismissal forgets itself on restart).
   */
  readonly shareIdToDiscard: string | null;
}

export const EMPTY_INCOMING_SHARE_PRESENTATION_STATE: IncomingSharePresentationState = {
  presentedShareId: null,
  dismissedShareId: null,
};

export function transitionIncomingSharePresentation(
  state: IncomingSharePresentationState,
  input: {
    readonly isShareSheetPresented: boolean;
    readonly pendingShareId: string | null;
  },
): IncomingSharePresentationTransition {
  if (input.isShareSheetPresented) {
    if (state.presentedShareId !== null && input.pendingShareId !== state.presentedShareId) {
      // Forget consumed presentations immediately so later handoffs can reuse their ids.
      return {
        state: EMPTY_INCOMING_SHARE_PRESENTATION_STATE,
        shareIdToPresent: null,
        shareIdToDiscard: null,
      };
    }
    return { state, shareIdToPresent: null, shareIdToDiscard: null };
  }

  let nextState = state;
  if (state.presentedShareId !== null) {
    if (input.pendingShareId === state.presentedShareId) {
      return {
        state: {
          presentedShareId: null,
          dismissedShareId: state.presentedShareId,
        },
        shareIdToPresent: null,
        shareIdToDiscard: state.presentedShareId,
      };
    }
    nextState = { ...state, presentedShareId: null };
  }

  if (input.pendingShareId === null) {
    return {
      state: EMPTY_INCOMING_SHARE_PRESENTATION_STATE,
      shareIdToPresent: null,
      shareIdToDiscard: null,
    };
  }

  if (nextState.dismissedShareId === input.pendingShareId) {
    return { state: nextState, shareIdToPresent: null, shareIdToDiscard: null };
  }

  return {
    state: {
      presentedShareId: input.pendingShareId,
      dismissedShareId: null,
    },
    shareIdToPresent: input.pendingShareId,
    shareIdToDiscard: null,
  };
}
