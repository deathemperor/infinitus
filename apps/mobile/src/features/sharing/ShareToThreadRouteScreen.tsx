import type { EnvironmentThreadShell } from "@infinitus/client-runtime/state/shell";
import { LegendList } from "@legendapp/list/react-native";
import { StackActions, useNavigation, type StaticScreenProps } from "@react-navigation/native";
import * as Haptics from "expo-haptics";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Alert, Platform, Pressable, ScrollView, TextInput, View } from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";

import { AndroidScreenHeader } from "../../components/AndroidScreenHeader";
import { SymbolView } from "../../components/AppSymbol";
import { AppText as Text } from "../../components/AppText";
import { MaterialListRow } from "../../components/MaterialListRow";
import { MaterialScreenContent } from "../../components/MaterialScreenContent";
import { cn } from "../../lib/cn";
import { scopedThreadKey } from "../../lib/scopedEntities";
import { NativeHeaderToolbar, NativeStackScreenOptions } from "../../native/StackHeader";
import { appAtomRegistry } from "../../state/atom-registry";
import { useProjects, useThreadShells } from "../../state/entities";
import { serverEnvironment } from "../../state/server";
import {
  getComposerDraftSnapshot,
  mergeComposerDraftContent,
  scheduleUnusedComposerAttachmentCleanup,
} from "../../state/use-composer-drafts";
import {
  createNativeMailSearchToolbarItem,
  NATIVE_MAIL_SEARCH_TOOLBAR_CONTENT_INSET,
  NATIVE_MAIL_SEARCH_TOOLBAR_SUPPORTED,
} from "../layout/native-mail-search-toolbar";
import { selectIncomingShareAttachmentsForServer } from "./incoming-share-model";
import { useIncomingShare } from "./IncomingShareProvider";
import { selectShareTargetThreads, type ShareTargetThread } from "./share-to-thread";

type ShareToThreadRouteParams = {
  readonly incomingShareId: string;
};

function ThreadRow(props: {
  readonly row: ShareTargetThread;
  readonly disabled: boolean;
  readonly isFirst: boolean;
  readonly isLast: boolean;
  readonly onSelect: (thread: EnvironmentThreadShell) => void;
}) {
  const { onSelect } = props;
  const { thread } = props.row;
  const onPress = useCallback(() => onSelect(thread), [onSelect, thread]);
  const subtitle = props.row.projectTitle ?? undefined;
  return (
    <View
      className={cn(
        props.isFirst &&
          (Platform.OS === "android"
            ? "overflow-hidden rounded-t-[28px]"
            : "overflow-hidden rounded-t-2xl"),
        props.isLast &&
          (Platform.OS === "android"
            ? "overflow-hidden rounded-b-[28px]"
            : "overflow-hidden rounded-b-2xl"),
      )}
    >
      {Platform.OS === "android" ? (
        <MaterialListRow
          title={thread.title}
          subtitle={subtitle}
          disabled={props.disabled}
          onPress={onPress}
          leading={
            <SymbolView name="text.bubble" size={24} tintColorClassName="accent-icon-muted" />
          }
        />
      ) : (
        <Pressable
          accessibilityRole="button"
          accessibilityLabel={[thread.title, subtitle].filter(Boolean).join(", ")}
          className={cn(
            "min-h-14 flex-row items-center gap-3 bg-card px-4 py-3 active:bg-subtle",
            !props.isLast && "border-b border-border-subtle",
          )}
          disabled={props.disabled}
          onPress={onPress}
          style={{ opacity: props.disabled ? 0.45 : 1 }}
        >
          <SymbolView
            name="text.bubble"
            size={17}
            tintColorClassName="accent-icon-muted"
            type="monochrome"
          />
          <View className="min-w-0 flex-1 gap-0.5">
            <Text className="text-base font-infinitus-medium text-foreground" numberOfLines={1}>
              {thread.title}
            </Text>
            {subtitle ? (
              <Text className="text-xs text-foreground-muted" numberOfLines={1}>
                {subtitle}
              </Text>
            ) : null}
          </View>
          <SymbolView
            name="chevron.right"
            size={14}
            tintColorClassName="accent-chevron"
            type="monochrome"
          />
        </Pressable>
      )}
    </View>
  );
}

/**
 * Lands a native share in an existing thread: the share merges into that
 * thread's composer draft and the thread opens, so the user reviews and sends
 * from there just like a new-task draft.
 */
export function ShareToThreadRouteScreen({
  route,
}: StaticScreenProps<ShareToThreadRouteParams | undefined>) {
  const navigation = useNavigation();
  const insets = useSafeAreaInsets();
  const threads = useThreadShells();
  const projects = useProjects();
  const { consumeShare, getShare } = useIncomingShare();
  const [query, setQuery] = useState("");
  const [importingThreadKey, setImportingThreadKey] = useState<string | null>(null);
  const mountedRef = useRef(true);
  const usesNativeMailSearchToolbar = Platform.OS === "ios" && NATIVE_MAIL_SEARCH_TOOLBAR_SUPPORTED;
  const rows = useMemo(
    () => selectShareTargetThreads({ threads, projects, query }),
    [projects, query, threads],
  );
  const listContentStyle = useMemo(
    () => ({
      paddingBottom: usesNativeMailSearchToolbar
        ? NATIVE_MAIL_SEARCH_TOOLBAR_CONTENT_INSET + 16
        : Platform.OS === "ios"
          ? 16
          : Math.max(insets.bottom, 16) + 16,
      paddingHorizontal: 16,
      paddingTop: 16,
    }),
    [insets.bottom, usesNativeMailSearchToolbar],
  );

  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
    };
  }, []);

  const selectThread = useCallback(
    async (thread: EnvironmentThreadShell) => {
      if (importingThreadKey !== null) {
        return;
      }
      const shareId = route.params?.incomingShareId;
      const incomingShare = shareId ? getShare(shareId) : null;
      if (!shareId || !incomingShare) {
        Alert.alert("Shared content unavailable", "The shared content is no longer in the inbox.");
        navigation.goBack();
        return;
      }
      const selectedAttachments = selectIncomingShareAttachmentsForServer({
        attachments: incomingShare.attachments,
        serverConfig: appAtomRegistry.get(serverEnvironment.configValueAtom(thread.environmentId)),
      });
      if (selectedAttachments.status === "pending") {
        Alert.alert(
          "Environment still connecting",
          "Wait for the thread's environment to connect, then choose it again.",
        );
        return;
      }
      const draftKey = scopedThreadKey(thread.environmentId, thread.id);
      setImportingThreadKey(draftKey);
      void Haptics.selectionAsync();
      try {
        // Merge before consuming: the draft's importedShareIds receipt makes a
        // retry into the same thread a no-op if the app dies in between.
        const { skippedAttachmentCount } = await mergeComposerDraftContent(draftKey, {
          text: incomingShare.text,
          attachments: selectedAttachments.attachments,
          sourceShareId: shareId,
        });
        await consumeShare(shareId);
        // The consumed inbox item was the last owner of files the draft did not
        // keep (unsupported server, oversize, limit skips).
        const retainedAttachmentIds = new Set(
          getComposerDraftSnapshot(draftKey).attachments.map((attachment) => attachment.id),
        );
        scheduleUnusedComposerAttachmentCleanup(
          incomingShare.attachments.filter(
            (attachment) => !retainedAttachmentIds.has(attachment.id),
          ),
        );
        const warnings = [...incomingShare.warnings, ...selectedAttachments.warnings];
        if (skippedAttachmentCount > 0) {
          warnings.push(
            `${skippedAttachmentCount} shared file${skippedAttachmentCount === 1 ? " was" : "s were"} skipped because this thread's draft reached the attachment limit.`,
          );
        }
        if (warnings.length > 0) {
          Alert.alert("Some shared content was skipped", warnings.join("\n"));
        }
      } catch (error) {
        if (mountedRef.current) {
          setImportingThreadKey(null);
          Alert.alert(
            "Could not import shared content",
            error instanceof Error ? error.message : "The shared content could not be saved.",
          );
        }
        return;
      }
      if (!mountedRef.current) {
        return;
      }
      (navigation.getParent() ?? navigation).dispatch(
        StackActions.replace("Thread", {
          environmentId: thread.environmentId,
          threadId: thread.id,
        }),
      );
    },
    [consumeShare, getShare, importingThreadKey, navigation, route.params?.incomingShareId],
  );

  const renderRow = useCallback(
    ({ item, index }: { readonly item: ShareTargetThread; readonly index: number }) => (
      <ThreadRow
        disabled={importingThreadKey !== null}
        isFirst={index === 0}
        isLast={index === rows.length - 1}
        onSelect={selectThread}
        row={item}
      />
    ),
    [importingThreadKey, rows.length, selectThread],
  );

  const content =
    rows.length === 0 ? (
      <ScrollView
        className={Platform.OS === "android" ? "flex-1 bg-sheet-solid" : "flex-1 bg-sheet"}
        contentInsetAdjustmentBehavior="automatic"
        contentContainerStyle={{ flexGrow: 1, paddingHorizontal: 16, paddingTop: 16 }}
        scrollEnabled={false}
        showsVerticalScrollIndicator={false}
      >
        <View
          className="flex-1 items-center justify-center gap-3 px-4"
          style={{
            marginBottom: usesNativeMailSearchToolbar
              ? NATIVE_MAIL_SEARCH_TOOLBAR_CONTENT_INSET
              : 0,
          }}
        >
          <Text className="text-center text-sm text-foreground-muted">
            {query.trim() ? "No matching threads" : "No threads yet"}
          </Text>
        </View>
      </ScrollView>
    ) : (
      <LegendList
        alwaysBounceVertical={false}
        automaticallyAdjustsScrollIndicatorInsets
        automaticallyAdjustKeyboardInsets={Platform.OS === "ios"}
        className={Platform.OS === "android" ? "flex-1 bg-sheet-solid" : "flex-1 bg-sheet"}
        contentInsetAdjustmentBehavior="automatic"
        contentContainerStyle={listContentStyle}
        data={rows}
        keyboardDismissMode={Platform.OS === "ios" ? "interactive" : "on-drag"}
        keyboardShouldPersistTaps="handled"
        keyExtractor={(row) => scopedThreadKey(row.thread.environmentId, row.thread.id)}
        renderItem={renderRow}
        showsVerticalScrollIndicator={false}
      />
    );

  if (Platform.OS === "android") {
    return (
      <View className="flex-1 bg-sheet" collapsable={false}>
        <NativeStackScreenOptions options={{ headerShown: false }} />
        <AndroidScreenHeader
          title="Choose thread"
          hideBottomBorder
          onBack={() => navigation.goBack()}
        />
        <View className="bg-header px-4 pb-3 pt-1">
          <TextInput
            autoCapitalize="none"
            autoCorrect={false}
            accessibilityLabel="Find a thread"
            className="h-12 rounded-full border border-input-border bg-input px-4 font-sans text-base text-foreground"
            selectionColorClassName="accent-primary/32"
            cursorColorClassName="accent-primary"
            selectionHandleColorClassName="accent-primary"
            onChangeText={setQuery}
            placeholder="Find a thread"
            placeholderTextColorClassName="accent-placeholder"
            value={query}
          />
        </View>
        <MaterialScreenContent>{content}</MaterialScreenContent>
      </View>
    );
  }

  return (
    <>
      <NativeStackScreenOptions
        options={{
          headerShown: true,
          title: "Choose thread",
          unstable_headerToolbarItems: usesNativeMailSearchToolbar
            ? () => [
                createNativeMailSearchToolbarItem({
                  onSearchTextChange: setQuery,
                  placeholder: "Find a thread",
                  searchTextChangeId: "share-to-thread-search-text",
                  showsSearchDismissButton: true,
                }),
              ]
            : undefined,
          headerSearchBarOptions: usesNativeMailSearchToolbar
            ? undefined
            : {
                allowToolbarIntegration: true,
                autoCapitalize: "none",
                hideNavigationBar: false,
                obscureBackground: false,
                placeholder: "Find a thread",
                onChangeText: (event) => {
                  setQuery(event.nativeEvent.text);
                },
                onCancelButtonPress: () => {
                  setQuery("");
                },
              },
        }}
      />
      {usesNativeMailSearchToolbar ? null : (
        <NativeHeaderToolbar placement="bottom">
          <NativeHeaderToolbar.SearchBarSlot />
        </NativeHeaderToolbar>
      )}
      {content}
    </>
  );
}
