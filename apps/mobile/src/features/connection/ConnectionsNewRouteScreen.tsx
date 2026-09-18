import { ScreenScrollView as ScrollView } from "../../components/ScreenScrollView";
import { CameraView, useCameraPermissions } from "expo-camera";
import Constants from "expo-constants";
import { NativeHeaderToolbar, NativeStackScreenOptions } from "../../native/StackHeader";
import {
  StackActions,
  useNavigation,
  useRoute,
  type StaticScreenProps,
} from "@react-navigation/native";
import { AsyncResult } from "effect/unstable/reactivity";
import { useCallback, useEffect, useRef, useState } from "react";
import { Alert, Linking, Platform, View } from "react-native";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { useUniwindTheme } from "../../lib/useUniwindTheme";
import { SettingsScreen } from "../settings/components/SettingsScreen";
import { AppText as Text, AppTextInput as TextInput } from "../../components/AppText";
import { ErrorBanner } from "../../components/ErrorBanner";
import { InfinitusAskToApprove } from "../infinitus/InfinitusAskToApprove";
import { InfinitusNearbyServers } from "../infinitus/InfinitusNearbyServers";
import { resolvePairingLink } from "./universalPairLink.logic";
import { PICKED_HOST_HINT, pickedHostNeedsCode } from "../infinitus/lanDiscovery.logic";
import { ConnectionSheetButton } from "./ConnectionSheetButton";
import {
  buildPairingUrl,
  extractPairingUrlFromQrPayload,
  missingPairingInput,
  parsePairingUrl,
} from "./pairing";
import { useRemoteConnections } from "../../state/use-remote-environment-registry";
import { routePairingPrefill } from "./pairPrefill.logic";

type ConnectionsNewRouteParams = {
  readonly mode?: string;
  readonly pairingUrl?: string;
  readonly autoConnect?: string;
};

export function ConnectionsNewRouteScreen({
  route,
}: StaticScreenProps<ConnectionsNewRouteParams | undefined>) {
  const {
    connectionPairingUrl,
    onChangeConnectionPairingUrl,
    onConnectPress,
    pairingConnectionError,
  } = useRemoteConnections();
  const navigation = useNavigation();
  const routeName = useRoute().name;
  const params = route.params ?? {};
  // Deep-link prefill: development, and the Infinitus variant's scanned QR
  // (#724); auto-connect stays development-only. See pairPrefill.logic.
  const { pairingUrl: routePairingUrl, autoConnect: shouldAutoConnect } = routePairingPrefill({
    params,
    dev: __DEV__,
    appVariant: Constants.expoConfig?.extra?.appVariant,
  });
  const insets = useSafeAreaInsets();
  const [hostInput, setHostInput] = useState("");
  const [codeInput, setCodeInput] = useState("");
  const [isSubmitting, setIsSubmitting] = useState(false);
  // What the form itself refuses before a connection is tried (#669).
  const [formError, setFormError] = useState<string | null>(null);
  const [showScanner, setShowScanner] = useState(params.mode === "scan_qr");
  const [cameraPermission, requestCameraPermission] = useCameraPermissions();
  const [scannerLocked, setScannerLocked] = useState(false);
  const attemptedAutoConnectRef = useRef<string | null>(null);
  // The Host a found Mac filled (#651): Add then waits for the code.
  const [pickedHost, setPickedHost] = useState<string | null>(null);

  const headerIconColor = useUniwindTheme()["--color-icon"];

  const needsCode = pickedHostNeedsCode({ pickedHost, hostInput, codeInput });
  const connectDisabled = isSubmitting || hostInput.trim().length === 0 || needsCode;

  useEffect(() => {
    const { host, code } = parsePairingUrl(connectionPairingUrl);
    setHostInput(host);
    setCodeInput(code);
  }, [connectionPairingUrl]);

  useEffect(() => {
    if (routePairingUrl.length === 0) {
      return;
    }

    const { host, code } = parsePairingUrl(routePairingUrl);
    setHostInput(host);
    setCodeInput(code);
  }, [routePairingUrl]);

  useEffect(() => {
    if (pairingConnectionError) {
      setIsSubmitting(false);
    }
  }, [pairingConnectionError]);

  const handleHostChange = useCallback((value: string) => {
    setHostInput(value);
    setFormError(null);
  }, []);

  const handleCodeChange = useCallback((value: string) => {
    setCodeInput(value);
    setFormError(null);
  }, []);

  const handleNearbyPick = useCallback(
    (host: string) => {
      handleHostChange(host);
      setPickedHost(host);
    },
    [handleHostChange],
  );

  const openScanner = useCallback(async () => {
    if (cameraPermission?.granted) {
      setScannerLocked(false);
      setShowScanner(true);
      return;
    }

    const permission = await requestCameraPermission();
    if (permission.granted) {
      setScannerLocked(false);
      setShowScanner(true);
      return;
    }

    if (permission.canAskAgain) {
      Alert.alert(
        "Camera access needed",
        "Allow camera access to scan an environment pairing QR code.",
      );
      return;
    }

    Alert.alert(
      "Camera access needed",
      "Camera access was denied for this app. Open Settings to enable it.",
      [
        { text: "Cancel", style: "cancel" },
        { text: "Open Settings", onPress: () => void Linking.openSettings() },
      ],
    );
  }, [cameraPermission?.granted, requestCameraPermission]);

  const closeScanner = useCallback(() => {
    setShowScanner(false);
    setScannerLocked(false);
  }, []);

  const handleQrScan = useCallback(
    ({ data }: { readonly data: string }) => {
      if (scannerLocked) {
        return;
      }

      setScannerLocked(true);

      try {
        // The Devices card's QR is the site's universal link (#724): read
        // the Mac's origin out of its fragment before the usual parse.
        const pairingUrl = resolvePairingLink(extractPairingUrlFromQrPayload(data));
        const { host, code } = parsePairingUrl(pairingUrl);
        setHostInput(host);
        setCodeInput(code);
        onChangeConnectionPairingUrl(pairingUrl);
        setShowScanner(false);
      } catch (error) {
        Alert.alert(
          "Invalid QR code",
          error instanceof Error ? error.message : "Scanned QR code was not recognized.",
        );
      } finally {
        setTimeout(() => {
          setScannerLocked(false);
        }, 600);
      }
    },
    [onChangeConnectionPairingUrl, scannerLocked],
  );

  const connectAndClose = useCallback(
    async (pairingUrl: string, replaceWithHome: boolean) => {
      setIsSubmitting(true);
      onChangeConnectionPairingUrl(pairingUrl);
      try {
        const result = await onConnectPress(pairingUrl);
        if (AsyncResult.isSuccess(result)) {
          if (replaceWithHome || !navigation.canGoBack()) {
            navigation.dispatch(StackActions.replace("Home"));
          } else {
            navigation.goBack();
          }
        }
      } finally {
        setIsSubmitting(false);
      }
    },
    [navigation, onChangeConnectionPairingUrl, onConnectPress],
  );

  const handleApprovedCredential = useCallback(
    (credential: string) => {
      void connectAndClose(buildPairingUrl(hostInput, credential), false);
    },
    [connectAndClose, hostInput],
  );

  const handleSubmit = useCallback(async () => {
    const missing = missingPairingInput(hostInput, codeInput);
    setFormError(missing);
    if (missing !== null) {
      return;
    }
    await connectAndClose(buildPairingUrl(hostInput, codeInput), false);
  }, [codeInput, connectAndClose, hostInput]);

  useEffect(() => {
    if (!shouldAutoConnect || attemptedAutoConnectRef.current === routePairingUrl) {
      return;
    }

    attemptedAutoConnectRef.current = routePairingUrl;
    void connectAndClose(routePairingUrl, true);
  }, [connectAndClose, routePairingUrl, shouldAutoConnect]);

  return (
    <SettingsScreen
      formSheet={routeName === "ConnectionsNew"}
      title={showScanner ? "Scan QR Code" : "Add Environment"}
      actions={[
        {
          accessibilityLabel: showScanner ? "Close scanner" : "Scan QR code",
          icon: showScanner ? "xmark" : "camera",
          onPress: () => {
            if (showScanner) {
              closeScanner();
            } else {
              void openScanner();
            }
          },
        },
      ]}
    >
      <NativeStackScreenOptions
        options={{ title: showScanner ? "Scan QR Code" : "Add Environment" }}
      />
      {Platform.OS !== "android" ? (
        <NativeHeaderToolbar placement="right">
          <NativeHeaderToolbar.Button
            icon={showScanner ? "xmark" : "qrcode.viewfinder"}
            onPress={() => {
              if (showScanner) {
                closeScanner();
              } else {
                void openScanner();
              }
            }}
            separateBackground
            tintColor={headerIconColor}
          />
        </NativeHeaderToolbar>
      ) : null}

      <ScrollView
        contentInsetAdjustmentBehavior="automatic"
        showsVerticalScrollIndicator={false}
        className="flex-1"
        contentInset={{ bottom: Math.max(insets.bottom, 18) + 18 }}
        contentContainerStyle={{
          paddingHorizontal: 20,
          paddingTop: 16,
        }}
      >
        <View collapsable={false} className="gap-5">
          {showScanner ? (
            cameraPermission?.granted ? (
              <View className="overflow-hidden rounded-[24px] border-continuous">
                <CameraView
                  barcodeScannerSettings={{ barcodeTypes: ["qr"] }}
                  onBarcodeScanned={handleQrScan}
                  style={{ aspectRatio: 1, width: "100%" }}
                />
              </View>
            ) : (
              <View className="items-center gap-3 rounded-[24px] border-continuous bg-card px-5 py-8">
                <Text className="text-center text-sm leading-normal text-foreground-muted">
                  Camera permission is required to scan a QR code.
                </Text>
                <ConnectionSheetButton
                  compact
                  icon="camera"
                  label="Allow camera"
                  tone="secondary"
                  onPress={() => {
                    void openScanner();
                  }}
                />
              </View>
            )
          ) : (
            <View collapsable={false} className="gap-4 rounded-[24px] bg-card p-4">
              <InfinitusNearbyServers onPick={handleNearbyPick} />
              <View collapsable={false} className="gap-1.5">
                <Text className="text-2xs font-infinitus-bold tracking-[0.8px] uppercase text-foreground-muted">
                  Host
                </Text>
                <TextInput
                  autoCapitalize="none"
                  autoCorrect={false}
                  keyboardType="url"
                  placeholder="192.168.1.100:8080"
                  value={hostInput}
                  onChangeText={handleHostChange}
                  className="rounded-[14px] border border-input-border bg-input px-4 py-3.5 text-base text-foreground"
                />
              </View>

              <View collapsable={false} className="gap-1.5">
                <Text className="text-2xs font-infinitus-bold tracking-[0.8px] uppercase text-foreground-muted">
                  Pairing code
                </Text>
                <TextInput
                  autoCapitalize="none"
                  autoCorrect={false}
                  placeholder="abc-123-xyz"
                  value={codeInput}
                  onChangeText={handleCodeChange}
                  className="rounded-[14px] border border-input-border bg-input px-4 py-3.5 text-base text-foreground"
                />
                {needsCode ? (
                  <Text accessibilityLiveRegion="polite" className="text-xs text-foreground-muted">
                    {PICKED_HOST_HINT}
                  </Text>
                ) : null}
              </View>
              <InfinitusAskToApprove
                host={hostInput}
                disabled={isSubmitting}
                onCredential={handleApprovedCredential}
              />

              {formError !== null ? (
                <ErrorBanner message={formError} />
              ) : pairingConnectionError ? (
                <ErrorBanner message={pairingConnectionError} />
              ) : null}

              <View className={Platform.OS === "android" ? "flex-row justify-end" : undefined}>
                <ConnectionSheetButton
                  icon="plus"
                  label={isSubmitting ? "Pairing..." : "Add environment"}
                  disabled={connectDisabled}
                  tone="primary"
                  onPress={() => {
                    void handleSubmit();
                  }}
                />
              </View>
            </View>
          )}
        </View>
      </ScrollView>
    </SettingsScreen>
  );
}
