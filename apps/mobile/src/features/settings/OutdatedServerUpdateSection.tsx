import { useGT, useMessages } from "gt-react-native";
import { useAtom, useAtomValue } from "@effect/atom-react";
import { serverUpdateFailureText } from "@infinitus/client-runtime/state/server";
import { squashAtomCommandFailure } from "@infinitus/client-runtime/state/runtime";
import type { EnvironmentId } from "@infinitus/contracts";
import { PRODUCT_NAME } from "@infinitus/shared/productName";
import { AsyncResult } from "effect/reactivity";
import { useState } from "react";
import { View } from "react-native";

import { AppText as Text } from "../../components/ui/AppText";
import * as Dialog from "../../components/ui/Dialog";
import {
  describeOutdatedServer,
  serverEnvironment,
  updateOutdatedServer,
} from "../../state/server";
import { useAtomCommand } from "../../state/use-atom-command";
import { ListActionRow as SettingsActionRow } from "../../components/ui/ListActionRow";
import { SettingsSection } from "./components/SettingsSection";
import {
  environmentReleaseCheckAtom,
  releaseCheckError,
  releaseCheckValue,
} from "./environmentUpdateCheck";

export function OutdatedServerUpdateSection({
  environmentId,
  label,
}: {
  readonly environmentId: EnvironmentId;
  readonly label: string;
}) {
  const gt = useGT();
  const messages = useMessages();
  const describe = useAtomCommand(describeOutdatedServer, { reportFailure: false });
  const update = useAtomCommand(updateOutdatedServer, { reportFailure: false });
  const state = useAtomValue(serverEnvironment.updateStateAtom(environmentId));
  const [checkResult, startCheck] = useAtom(environmentReleaseCheckAtom(environmentId));
  const release = releaseCheckValue(checkResult);
  const checking = checkResult.waiting;
  // Starting an update replaces a failed check's message with the update's own state.
  const [checkErrorDismissed, setCheckErrorDismissed] = useState(false);
  const error = checkErrorDismissed ? null : releaseCheckError(checkResult);
  const busy = checking || state.status === "running";

  function check() {
    if (busy) return;
    setCheckErrorDismissed(false);
    startCheck(async () => {
      const description = await describe(environmentId);
      if (AsyncResult.isFailure(description)) throw squashAtomCommandFailure(description);
      return description.value.serverVersion;
    });
  }

  function requestUpdate() {
    const targetVersion = release?.targetVersion;
    if (busy || !release || !targetVersion) return;
    Dialog.alert(
<<<<<<< HEAD
      `Update ${label}?`,
      `Install ${PRODUCT_NAME} ${targetVersion}. ${PRODUCT_NAME} restarts on that machine and reconnects. Running threads may be interrupted.`,
=======
      gt("Update {environment}?", { environment: label }),
      gt(
        "Install {product} {version}. {product} restarts on that machine and reconnects. Running threads may be interrupted.",
        { product: "T3 Code", version: targetVersion },
      ),
>>>>>>> upstream-sync-df09ced768-upstream-renamed
      [
        { text: gt("Cancel"), style: "cancel" },
        {
          text: gt("Update", { $context: "verb, install an update" }),
          onPress: () => {
            setCheckErrorDismissed(true);
            void update({
              environmentId,
              input: { targetVersion },
              fromVersion: release.fromVersion,
            });
          },
        },
      ],
    );
  }

  return (
    <SettingsSection title={PRODUCT_NAME}>
      <View className="gap-1 p-4">
        <Text className="text-base text-foreground">
          {release
            ? gt("Version {version}", { version: release.fromVersion })
            : gt("Update required")}
        </Text>
        <Text className="text-sm text-foreground-muted">
          {state.status === "running"
            ? state.stage === "resuming"
              ? gt("Restarting and reconnecting…")
              : state.stage === "installing"
                ? gt("Installing update…")
                : gt("Downloading update…")
            : release
              ? release.targetVersion
<<<<<<< HEAD
                ? `Version ${release.targetVersion} is available.`
                : "No newer version is available yet."
              : `This app needs a newer version of ${PRODUCT_NAME} on this machine.`}
=======
                ? gt("Version {version} is available.", { version: release.targetVersion })
                : gt("No newer version is available yet.")
              : gt("This app needs a newer version of {product} on this machine.", {
                  product: "T3 Code",
                })}
>>>>>>> upstream-sync-df09ced768-upstream-renamed
        </Text>
        {error || state.status === "failed" ? (
          <Text selectable accessibilityRole="alert" className="text-sm text-danger-foreground">
            {error ?? (state.status === "failed" ? serverUpdateFailureText(state, messages) : null)}
          </Text>
        ) : null}
      </View>
      <SettingsActionRow
        icon="arrow.clockwise"
        label={gt("Check for updates")}
        disabled={busy}
        loading={checking}
        onPress={check}
      />
      {release?.targetVersion ? (
        <SettingsActionRow
          icon="arrow.up.circle"
          label={
            state.status === "failed"
              ? gt("Retry update")
              : gt("Update to {version}", { version: release.targetVersion })
          }
          disabled={busy}
          loading={state.status === "running"}
          onPress={requestUpdate}
        />
      ) : null}
    </SettingsSection>
  );
}
