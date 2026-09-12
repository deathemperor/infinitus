import {
  isAtomCommandInterrupted,
  squashAtomCommandFailure,
} from "@t3tools/client-runtime/state/runtime";
import { EnvironmentId, MessageId, ThreadId } from "@t3tools/contracts";
import { useNavigation, type StaticScreenProps } from "@react-navigation/native";
import * as Option from "effect/Option";
import { useMemo, useState } from "react";
import { ActivityIndicator, Platform, ScrollView, View } from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";

import { AndroidSheetHeader } from "../../components/AndroidScreenHeader";
import { AppText as Text, AppTextInput as TextInput } from "../../components/AppText";
import { scopedThreadKey } from "../../lib/scopedEntities";
import { uuidv4 } from "../../lib/uuid";
import { useEnvironmentThread, threadEnvironment } from "../../state/threads";
import { useAtomCommand } from "../../state/use-atom-command";
import { getComposerDraftSnapshot, setComposerDraftText } from "../../state/use-composer-drafts";
import { SheetActionButton } from "../threads/git/gitSheetComponents";
import { bringToMainText, isSideQuestionMessage, latestSideAnswer } from "./sideQuestions";

type SideQuestionSheetProps = StaticScreenProps<{
  readonly environmentId: string;
  /** The thread the question is about; "Bring to main" writes its draft. */
  readonly threadId: string;
  /** The hidden side fork the question runs in. */
  readonly sideThreadId: string;
}>;

/**
 * Fork (#269 C, #881): the side question as a sheet over its thread — the
 * web's drawer. Mounting the side thread's state atom starts its live sync,
 * so the answer streams in here; the imported history is told apart by
 * `isSideQuestionMessage`. A question starts a plan-mode turn on the side
 * fork (its own Claude session), so the main thread's turn is left alone.
 * "Bring to main" appends the latest answer to the main composer's draft
 * and closes the sheet.
 */
export function InfinitusSideQuestionSheet(props: SideQuestionSheetProps) {
  const navigation = useNavigation();
  const insets = useSafeAreaInsets();
  const environmentId = EnvironmentId.make(props.route.params.environmentId);
  const mainThreadId = ThreadId.make(props.route.params.threadId);
  const sideThreadId = ThreadId.make(props.route.params.sideThreadId);
  const state = useEnvironmentThread(environmentId, sideThreadId);
  const thread = Option.getOrNull(state.data);
  const startTurn = useAtomCommand(threadEnvironment.startTurn, { reportFailure: false });
  const [text, setText] = useState("");
  const [sending, setSending] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const messages = useMemo(
    () =>
      (thread?.messages ?? []).filter((message) => isSideQuestionMessage(sideThreadId, message)),
    [sideThreadId, thread?.messages],
  );
  const running = (thread?.session?.activeTurnId ?? null) !== null;
  const busy = sending || running;
  const answer = useMemo(() => latestSideAnswer(messages), [messages]);

  const send = async () => {
    const asked = text.trim();
    if (thread === null || asked.length === 0 || busy) return;
    setSending(true);
    setError(null);
    const result = await startTurn({
      environmentId,
      input: {
        threadId: sideThreadId,
        message: {
          messageId: MessageId.make(uuidv4()),
          role: "user",
          text: asked,
          attachments: [],
        },
        modelSelection: thread.modelSelection,
        runtimeMode: thread.runtimeMode,
        interactionMode: "plan",
        createdAt: new Date().toISOString(),
      },
    });
    setSending(false);
    if (result._tag === "Failure") {
      if (isAtomCommandInterrupted(result)) return;
      const failure = squashAtomCommandFailure(result);
      setError(failure instanceof Error ? failure.message : "Could not ask.");
      return;
    }
    setText("");
  };

  const bringToMain = () => {
    if (answer === null) return;
    const draftKey = scopedThreadKey(environmentId, mainThreadId);
    setComposerDraftText(
      draftKey,
      bringToMainText(getComposerDraftSnapshot(draftKey).text, answer),
    );
    navigation.goBack();
  };

  return (
    <View collapsable={false} className="flex-1 bg-sheet">
      {Platform.OS === "android" ? (
        <AndroidSheetHeader title="Side question" onBack={() => navigation.goBack()} />
      ) : null}
      <ScrollView
        className="flex-1"
        keyboardShouldPersistTaps="handled"
        showsVerticalScrollIndicator={false}
        contentInset={{ bottom: Math.max(insets.bottom, 18) + 18 }}
        contentContainerClassName="gap-4 px-5 pt-2"
      >
        {thread === null ? (
          <ActivityIndicator className="py-6" />
        ) : messages.length === 0 ? (
          <Text className="py-6 text-center text-sm leading-normal text-foreground-muted">
            Ask about the thread so far. The answer stays here; the main turn is left alone.
          </Text>
        ) : (
          <View className="gap-3">
            {messages.map((message) =>
              message.role === "user" ? (
                <View
                  key={message.id}
                  className="self-end rounded-[18px] bg-adaptive-neutral-100-900 px-4 py-2.5"
                >
                  <Text className="text-base text-foreground">{message.text}</Text>
                </View>
              ) : (
                <Text
                  key={message.id}
                  selectable
                  className="text-base leading-normal text-foreground"
                >
                  {message.text}
                </Text>
              ),
            )}
          </View>
        )}
        {running ? <ActivityIndicator /> : null}
        {error !== null ? (
          <Text className="text-xs leading-normal text-danger-foreground">{error}</Text>
        ) : null}
        <View className="gap-3">
          <TextInput
            multiline
            value={text}
            onChangeText={setText}
            placeholder="Ask a side question…"
            accessibilityLabel="Side question"
            editable={!busy}
            textAlignVertical="top"
            className="min-h-[96px] rounded-[20px] px-4 py-3.5"
          />
          <View className="flex-row gap-3">
            <View className="flex-1">
              <SheetActionButton
                icon="square.and.pencil"
                label="Bring to main"
                disabled={answer === null}
                onPress={bringToMain}
              />
            </View>
            <View className="flex-1">
              <SheetActionButton
                icon="arrow.up"
                label="Ask"
                tone="primary"
                disabled={busy || text.trim().length === 0}
                onPress={() => void send()}
              />
            </View>
          </View>
        </View>
      </ScrollView>
    </View>
  );
}
