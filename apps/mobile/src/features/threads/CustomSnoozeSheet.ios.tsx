import {
  Button,
  DatePicker,
  Host,
  HStack,
  Picker,
  Popover,
  Spacer,
  Text,
  VStack,
} from "@expo/ui/swift-ui";
import {
  accessibilityAddTraits,
  accessibilityHidden,
  buttonBorderShape,
  buttonStyle,
  clipped,
  controlSize,
  font,
  datePickerStyle,
  foregroundStyle,
  frame,
  labelsHidden,
  labelStyle,
  padding,
  pickerStyle,
  tag,
} from "@expo/ui/swift-ui/modifiers";
import {
  localSnoozeDate,
  localSnoozeTime,
  resolveCustomSnooze,
  type CustomSnoozeInput,
} from "@infinitus/client-runtime/state/thread-settled";
import { useState } from "react";
import { useWindowDimensions } from "react-native";
import { NATIVE_LIQUID_GLASS_SUPPORTED } from "../../native/native-glass";
import { useAppearancePreferences } from "../settings/appearance/AppearancePreferencesProvider";

const durationAmounts = Array.from({ length: 99 }, (_, index) => index + 1);
const modes = [
  { value: "date", label: "Date and time" },
  { value: "duration", label: "Duration" },
] as const;
const units = [
  { value: "minutes", label: "Minutes" },
  { value: "hours", label: "Hours" },
  { value: "days", label: "Days" },
] as const;

export function CustomSnoozeSheet(props: {
  readonly onClose: () => void;
  readonly onSnooze: (snoozedUntil: string) => void;
}) {
  const { width } = useWindowDimensions();
  const [mode, setMode] = useState<CustomSnoozeInput["mode"]>("date");
  const [date, setDate] = useState(() => new Date(Date.now() + 3_600_000));
  const [amount, setAmount] = useState(2);
  const [unit, setUnit] = useState<"minutes" | "hours" | "days">("hours");
  const [error, setError] = useState<string | null>(null);
  const { themeVariables: colors, themeAppearance } = useAppearancePreferences();
  const updateDate = (value: Date) => {
    setDate(value);
    setError(null);
  };

  const submit = () => {
    const input: CustomSnoozeInput =
      mode === "date"
        ? { mode, date: localSnoozeDate(date), time: localSnoozeTime(date) }
        : { mode, amount: String(amount), unit };
    const snoozedUntil = resolveCustomSnooze(input, new Date());
    if (!snoozedUntil) {
      setError(
        mode === "date" ? "Choose a date and time in the future." : "Enter a positive duration.",
      );
      return;
    }
    props.onSnooze(snoozedUntil);
    props.onClose();
  };

  return (
<<<<<<< HEAD
    <Modal visible transparent animationType="fade" onRequestClose={props.onClose}>
      <View className="flex-1 items-center justify-center bg-black/40 px-6">
        <ScrollView
          className="max-h-[80%] w-full max-w-sm grow-0 rounded-3xl border border-border bg-sheet-solid"
          contentContainerStyle={{ padding: 20, gap: 16 }}
        >
          <View className="flex-row items-center justify-between gap-2">
            <Pressable accessibilityRole="button" onPress={props.onClose} hitSlop={10}>
              <AppText className="text-base">Cancel</AppText>
            </Pressable>
            <AppText accessibilityRole="header" className="text-base font-infinitus-semibold">
              Custom snooze
            </AppText>
            <Pressable accessibilityRole="button" onPress={submit} hitSlop={10}>
              <AppText className="text-base text-primary">Snooze</AppText>
            </Pressable>
          </View>
          <SegmentedControl
            options={modes}
            selected={mode}
            onSelect={(value) => {
              setMode(value);
              setError(null);
            }}
            role="tab"
          />
          <Host
            matchContents={{ vertical: true }}
            style={{ width: "100%" }}
            colorScheme={themeAppearance}
            seedColor={colors["--color-primary"]}
          >
            <HStack
              spacing={6}
              modifiers={[
                frame({ minHeight: 44 }),
                foregroundStyle(colors["--color-foreground"]),
                font({ size: appearance.baseFontSize }),
              ]}
            >
              <Text>{mode === "date" ? "Until" : "Snooze for"}</Text>
              <Spacer />
              {mode === "date" ? (
                <>
                  <SnoozeDateField date={date} component="date" onChange={updateDate} />
                  <SnoozeDateField date={date} component="hourAndMinute" onChange={updateDate} />
                </>
              ) : (
                <>
                  <Popover isPresented={amountOpen} onIsPresentedChange={setAmountOpen}>
                    <Popover.Trigger>
                      <Button
                        onPress={() => setAmountOpen(true)}
                        modifiers={[buttonStyle("plain")]}
                      >
                        <FieldLabel label={String(amount)} />
                      </Button>
                    </Popover.Trigger>
                    <Popover.Content>
                      <VStack
                        modifiers={[
                          padding({ all: 12 }),
                          frame({ width: 180 }),
                          presentationBackground(colors["--color-sheet-solid"]),
                        ]}
                      >
                        <Picker
                          label="Duration"
                          selection={amount}
                          onSelectionChange={(value: number) => {
                            setAmount(value);
                            setError(null);
                          }}
                          modifiers={[pickerStyle("wheel"), frame({ height: 160 })]}
                        >
                          {durationAmounts.map((value) => (
                            <Text
                              key={value}
                              modifiers={[
                                tag(value),
                                foregroundStyle(colors["--color-foreground"]),
                              ]}
                            >
                              {String(value)}
                            </Text>
                          ))}
                        </Picker>
                        <Button
                          label="Done"
                          onPress={() => setAmountOpen(false)}
                          modifiers={[foregroundStyle(colors["--color-primary"])]}
                        />
                      </VStack>
                    </Popover.Content>
                  </Popover>
                  <Menu
                    label={
                      <FieldLabel
                        label={unit === "minutes" ? "Minutes" : unit === "hours" ? "Hours" : "Days"}
                      />
                    }
                  >
                    {units.map((option) => (
                      <Button
                        key={option.value}
                        label={option.label}
                        onPress={() => {
                          setUnit(option.value);
                          setError(null);
                        }}
                      />
                    ))}
                  </Menu>
                </>
              )}
            </HStack>
          </Host>
          {error && <AppText className="text-sm text-danger-foreground">{error}</AppText>}
        </ScrollView>
      </View>
    </Modal>
  );
}

function FieldLabel(props: { readonly label: string }) {
  const { themeVariables: colors } = useAppearancePreferences();
  return (
    <Text
      modifiers={[
        padding({ horizontal: 12, vertical: 8 }),
        foregroundStyle(colors["--color-foreground"]),
        background(colors["--color-card"], shapes.capsule()),
      ]}
=======
    <Host
      style={{ position: "absolute", top: 0, right: 0, bottom: 0, left: 0 }}
      colorScheme={themeAppearance}
      seedColor={colors["--color-primary"]}
>>>>>>> upstream-sync-d4d5d12e8-upstream-renamed
    >
      <Popover
        isPresented
        onIsPresentedChange={(presented) => {
          if (!presented) props.onClose();
        }}
      >
        <Popover.Trigger>
          <Spacer
            modifiers={[frame({ maxWidth: Infinity, maxHeight: Infinity }), accessibilityHidden()]}
          />
        </Popover.Trigger>
        <Popover.Content>
          <VStack
            spacing={16}
            modifiers={[padding({ all: 16 }), frame({ width: Math.min(360, width - 32) })]}
          >
            <HStack spacing={12}>
              <Button
                label="Cancel"
                systemImage="xmark"
                role="cancel"
                onPress={props.onClose}
                modifiers={[
                  labelStyle("iconOnly"),
                  buttonStyle(NATIVE_LIQUID_GLASS_SUPPORTED ? "glass" : "bordered"),
                  buttonBorderShape("circle"),
                  controlSize("large"),
                ]}
              />
              <Text
                modifiers={[
                  font({ textStyle: "headline" }),
                  frame({ maxWidth: Infinity, alignment: "leading" }),
                  accessibilityAddTraits(["isHeader"]),
                ]}
              >
                Custom snooze
              </Text>
              <Button
                label="Snooze"
                onPress={submit}
                modifiers={[
                  buttonStyle(
                    NATIVE_LIQUID_GLASS_SUPPORTED ? "glassProminent" : "borderedProminent",
                  ),
                  controlSize("large"),
                ]}
              />
            </HStack>
            <Picker
              label="Snooze mode"
              selection={mode}
              onSelectionChange={(value: CustomSnoozeInput["mode"]) => {
                setMode(value);
                setError(null);
              }}
              modifiers={[pickerStyle("segmented")]}
            >
              {modes.map((option) => (
                <Text key={option.value} modifiers={[tag(option.value)]}>
                  {option.label}
                </Text>
              ))}
            </Picker>
            {mode === "date" ? (
              <DatePicker
                title="Snooze until"
                selection={date}
                displayedComponents={["date", "hourAndMinute"]}
                onDateChange={updateDate}
                modifiers={[
                  datePickerStyle("wheel"),
                  labelsHidden(),
                  frame({ maxWidth: Infinity, height: 180 }),
                ]}
              />
            ) : (
              <HStack spacing={0}>
                <Picker
                  label="Duration amount"
                  selection={amount}
                  onSelectionChange={(value: number) => {
                    setAmount(value);
                    setError(null);
                  }}
                  modifiers={[
                    pickerStyle("wheel"),
                    labelsHidden(),
                    frame({ minWidth: 0, maxWidth: Infinity, height: 180 }),
                    clipped(),
                  ]}
                >
                  {durationAmounts.map((value) => (
                    <Text
                      key={value}
                      modifiers={[tag(value), foregroundStyle(colors["--color-foreground"])]}
                    >
                      {String(value)}
                    </Text>
                  ))}
                </Picker>
                <Picker
                  label="Duration unit"
                  selection={unit}
                  onSelectionChange={(value: typeof unit) => {
                    setUnit(value);
                    setError(null);
                  }}
                  modifiers={[
                    pickerStyle("wheel"),
                    labelsHidden(),
                    frame({ minWidth: 0, maxWidth: Infinity, height: 180 }),
                    clipped(),
                  ]}
                >
                  {units.map((option) => (
                    <Text
                      key={option.value}
                      modifiers={[tag(option.value), foregroundStyle(colors["--color-foreground"])]}
                    >
                      {option.label}
                    </Text>
                  ))}
                </Picker>
              </HStack>
            )}
            {error ? (
              <Text
                modifiers={[
                  font({ textStyle: "footnote" }),
                  foregroundStyle(colors["--color-danger-foreground"]),
                ]}
              >
                {error}
              </Text>
            ) : null}
          </VStack>
        </Popover.Content>
      </Popover>
    </Host>
  );
}
