import { create } from "zustand";

/**
 * Whether the composer's Captures popover is open (#433), shared by the
 * shoulder badge that toggles it, the keyboard shortcuts and the palette
 * entry. `focusInputKey` ticks when the input should take focus on open.
 */
interface CapturesUiState {
  readonly open: boolean;
  readonly focusInputKey: number;
  readonly toggle: () => void;
  readonly show: (options?: { readonly focusInput?: boolean }) => void;
  readonly close: () => void;
}

export const useCapturesUiStore = create<CapturesUiState>((set) => ({
  open: false,
  focusInputKey: 0,
  toggle: () => set((state) => ({ open: !state.open })),
  show: (options) =>
    set((state) => ({
      open: true,
      focusInputKey: options?.focusInput ? state.focusInputKey + 1 : state.focusInputKey,
    })),
  close: () => set({ open: false }),
}));
