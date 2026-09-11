import { create } from "zustand";

/**
 * Whether the composer's Prompts popover (#270 G) is open, shared by the
 * shoulder badge that toggles it and the menu's own close paths.
 */
interface PromptsUiState {
  readonly open: boolean;
  readonly toggle: () => void;
  readonly close: () => void;
}

export const usePromptsUiStore = create<PromptsUiState>((set) => ({
  open: false,
  toggle: () => set((state) => ({ open: !state.open })),
  close: () => set({ open: false }),
}));
