import { Alert } from "react-native";

import { deletePendingThreadMessage } from "../../state/delete-pending-thread-message";
import type { QueuedThreadMessage } from "../../state/thread-outbox-model";

/** The trash under a queued reply's bubble (#1501); the pending-task delete on the home list is its sibling. */
export function confirmDeletePendingMessage(message: QueuedThreadMessage): void {
  Alert.alert(
    "Delete queued reply?",
    "This reply has not been sent yet and will be removed from the outbox.",
    [
      { text: "Cancel", style: "cancel" },
      {
        text: "Delete",
        style: "destructive",
        onPress: () => {
          void deletePendingThreadMessage(message)
            .then((deleted) => {
              if (!deleted) {
                Alert.alert("Could not delete reply", "It is being sent right now.");
              }
            })
            .catch((error) => {
              Alert.alert(
                "Could not delete reply",
                error instanceof Error ? error.message : "The reply could not be removed.",
              );
            });
        },
      },
    ],
  );
}
