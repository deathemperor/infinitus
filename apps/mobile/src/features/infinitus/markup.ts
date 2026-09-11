import { requireOptionalNativeModule } from "expo";
import { Platform } from "react-native";

interface InfinitusMarkupModule {
  /** Resolves with the edited file's URL, or null when the sheet closed without saving. */
  markUpImage(uri: string, title: string): Promise<string | null>;
}

/** The fork's `InfinitusMarkup` module (apps/mobile/modules/infinitus-markup): Quick
    Look with editing on over a copy of a draft image (#269 I). Null on Android and on
    an iOS build made before the module existed, where the composer shows no pencil. */
const native: InfinitusMarkupModule | null =
  Platform.OS === "ios"
    ? requireOptionalNativeModule<InfinitusMarkupModule>("InfinitusMarkup")
    : null;

export const markupSupported = native !== null;

export function markUpImage(uri: string, title: string): Promise<string | null> {
  return native === null ? Promise.resolve(null) : native.markUpImage(uri, title);
}
