import {
  type SignInFlow,
  signInEnded,
  signInPasteField,
  signInStatusText,
} from "@infinitus/client-runtime/state/infinitusSignIn";
import { useState } from "react";
import { View } from "react-native";

import { AppText as Text } from "../../components/ui/AppText";
import { Button } from "../../components/ui/Button";
import { SecretTextInput } from "../../components/ui/SecretTextInput";
import { cn } from "../../lib/cn";

/** A fleet's Add account button and, while a sign-in from this phone runs on it, where it stands:
    the page to open again, the field for the code or address, and Cancel. */
export function FleetSignInPanel(props: {
  readonly fleetTitle: string;
  /** This fleet's flow, if the phone started one on it. */
  readonly flow: SignInFlow | null;
  /** Some sign-in runs on the Mac (this one, another client's, the Mac's own). */
  readonly busy: boolean;
  readonly empty: boolean;
  readonly onAdd: () => void;
  readonly onCancel: () => void;
  readonly onReopen: () => void;
  readonly onSubmit: (text: string) => void;
}) {
  const { flow } = props;
  const [text, setText] = useState("");
  const running = flow !== null && !signInEnded(flow.phase);
  const pasteField = signInPasteField(flow);
  const status =
    flow !== null
      ? signInStatusText(flow)
      : props.busy
        ? "A sign-in is already running in Infinitus."
        : props.empty
          ? "No accounts yet. Add account starts the provider's sign-in."
          : null;
  const submit = (value: string) => {
    props.onSubmit(value);
    setText("");
  };
  return (
    <View className="gap-2 px-4 py-3">
      {status === null ? null : (
        <Text
          className={cn(
            "text-xs",
            flow?.phase === "failed" ? "text-danger-foreground" : "text-foreground-muted",
          )}
        >
          {status}
        </Text>
      )}
      {flow !== null && pasteField !== null ? (
        <View className="gap-2">
          <SecretTextInput
            accessibilityLabel={`Sign-in ${pasteField}: ${props.fleetTitle}`}
            placeholder={
              pasteField === "code" ? "Paste the code" : "Paste the address the browser ended on"
            }
            value={text}
            onChangeText={setText}
            onSubmitEditing={submit}
            editable={!flow.codeBusy}
          />
          <Button
            size="compact"
            tone="primary"
            label={pasteField === "code" ? "Submit code" : "Submit address"}
            loading={flow.codeBusy}
            disabled={text.trim() === ""}
            onPress={() => submit(text)}
          />
        </View>
      ) : null}
      {flow?.codeError ? (
        <Text className="text-xs text-danger-foreground">{flow.codeError}</Text>
      ) : null}
      <View className="flex-row flex-wrap items-center gap-2">
        {running && flow.url !== null ? (
          <Button
            size="compact"
            tone="secondary"
            label="Open sign-in page"
            accessibilityLabel={`Open the sign-in page: ${props.fleetTitle}`}
            disabled={flow.codeBusy}
            onPress={props.onReopen}
          />
        ) : null}
        {running ? (
          <Button
            size="compact"
            tone="text"
            label="Cancel"
            accessibilityLabel={`Cancel sign-in: ${props.fleetTitle}`}
            onPress={props.onCancel}
          />
        ) : (
          <Button
            size="compact"
            tone="secondary"
            icon="person.badge.plus"
            label="Add account"
            accessibilityLabel={`Add account: ${props.fleetTitle}`}
            disabled={props.busy}
            onPress={props.onAdd}
          />
        )}
      </View>
    </View>
  );
}
