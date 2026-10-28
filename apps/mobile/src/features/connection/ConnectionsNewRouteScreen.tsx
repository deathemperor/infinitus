import { ListRow } from "../../components/ui/ListRow";
import * as Dialog from "../../components/ui/Dialog";
import { ScreenScrollView as ScrollView } from "../../components/ui/ScreenScrollView";
import { useAuth } from "@clerk/expo";
import { CameraView, useCameraPermissions } from "expo-camera";
import Constants from "expo-constants";
import * as Haptics from "expo-haptics";
import {
  StackActions,
  useIsFocused,
  useNavigation,
  useRoute,
  type StaticScreenProps,
} from "@react-navigation/native";
import type { EnvironmentId } from "@infinitus/contracts";
import { useAtomValue } from "@effect/atom-react";
import { useState } from "react";
import { Linking, Pressable, StyleSheet, View } from "react-native";
import Svg, { Defs, RadialGradient, Rect, Stop } from "react-native-svg";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { cn } from "../../lib/cn";
import { useUniwindTheme } from "../../lib/useUniwindTheme";
import { useAppearancePreferences } from "../settings/appearance/AppearancePreferencesProvider";
import { SettingsScreen } from "../settings/components/SettingsScreen";
import { InfinitusAskToApprove } from "../infinitus/InfinitusAskToApprove";
import { InfinitusNearbyServers } from "../infinitus/InfinitusNearbyServers";
import { PICKED_HOST_HINT, pickedHostNeedsCode } from "../infinitus/lanDiscovery.logic";
import { AppText as Text, AppTextInput, type AppTextInputProps } from "../../components/ui/AppText";
import { FrostedCutout } from "../../components/ui/FrostedCutout";
import { buildPairingUrl, extractPairingUrlFromQrPayload, parsePairingUrl } from "./pairing";
import { useRemoteConnections } from "../../state/use-remote-environment-registry";
import { SymbolView } from "../../components/ui/AppSymbol";
import { hasCloudPublicConfig } from "../cloud/publicConfig";
import { CloudEnvironmentRows } from "./CloudEnvironmentRows";
import { autoConnectReport, devAutoConnectAttemptAtom } from "./devAutoConnect";
import { splitEnvironmentSections } from "./environmentSections";
import { routePairingPrefill } from "./pairPrefill.logic";
import { CONNECT_NAME } from "@infinitus/shared/productName";
import { leaveSettingsPage } from "../settings/settings-navigation";
import { workspaceHasColumns } from "../workspace/workspace-selection-store";

type ConnectionsNewRouteParams = {
  readonly mode?: string;
  readonly pairingUrl?: string;
  readonly autoConnect?: string;
  readonly routeFor?: EnvironmentId;
};

export function ConnectionsNewRouteScreen({
  route,
}: StaticScreenProps<ConnectionsNewRouteParams | undefined>) {
  const params = route.params ?? {};
<<<<<<< HEAD
  // Deep-link prefill: development, and the Infinitus variant's scanned QR
  // (#724); auto-connect stays development-only. See pairPrefill.logic.
  const { pairingUrl: routePairingUrl, autoConnect: shouldAutoConnect } = routePairingPrefill({
    params,
    dev: __DEV__,
    appVariant: Constants.expoConfig?.extra?.appVariant,
  });
=======
  // Dev-only prefill prevents production links from supplying an attacker-chosen host and token.
  const routePairingUrl = __DEV__ ? (params.pairingUrl?.trim() ?? "") : "";
  // A new prefill link replaces whatever the form held.
  return (
    <PairingForm
      key={routePairingUrl}
      routePairingUrl={routePairingUrl}
      routeFor={params.routeFor}
    />
  );
}

function PairingForm({
  routePairingUrl,
  routeFor,
}: {
  readonly routePairingUrl: string;
  readonly routeFor: EnvironmentId | undefined;
}) {
  const { connectionPairingUrl, onChangeConnectionPairingUrl, onConnectPress } =
    useRemoteConnections();
  const navigation = useNavigation();
  const routeName = useRoute().name;
>>>>>>> upstream-sync-a9418a120-upstream-renamed
  const insets = useSafeAreaInsets();
  const [initialPairing] = useState(() => parsePairingUrl(routePairingUrl || connectionPairingUrl));
  const [hostInput, setHostInput] = useState(initialPairing.host);
  const [codeInput, setCodeInput] = useState(initialPairing.code);
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [submitError, setSubmitError] = useState<string | null>(null);
  // The user's own edit or submit dismisses the dev auto-connect report.
  const [ownAttempt, setOwnAttempt] = useState(false);
  const autoConnect = autoConnectReport(
    useAtomValue(devAutoConnectAttemptAtom),
    routePairingUrl,
    ownAttempt,
  );
  const connecting = isSubmitting || autoConnect.connecting;
  const pairingConnectionError = submitError ?? autoConnect.error;
  const [cameraPermission, requestCameraPermission] = useCameraPermissions();
  const screenFocused = useIsFocused();
  const [scannerLocked, setScannerLocked] = useState(false);
  // A good scan parks the camera so it can't re-read the code over later edits.
  const [scanComplete, setScanComplete] = useState(false);
<<<<<<< HEAD
  const attemptedAutoConnectRef = useRef<string | null>(null);
  // The Host a found Mac filled (#651): Add then waits for the code.
  const [pickedHost, setPickedHost] = useState<string | null>(null);

  const headerIconColor = useUniwindTheme()["--color-icon"];

  const needsCode = pickedHostNeedsCode({ pickedHost, hostInput, codeInput });
  const connectDisabled = isSubmitting || hostInput.trim().length === 0 || needsCode;
=======

  const headerIconColor = useUniwindTheme()["--color-icon"];

  const connectDisabled = connecting || hostInput.trim().length === 0;
>>>>>>> upstream-sync-a9418a120-upstream-renamed

  const clearError = () => {
    setSubmitError(null);
    setOwnAttempt(true);
  };

  const handleHostChange = (value: string) => {
    setHostInput(value);
    clearError();
  };

  const handleCodeChange = (value: string) => {
    setCodeInput(value);
    clearError();
  };

<<<<<<< HEAD
  const handleNearbyPick = (host: string) => {
    handleHostChange(host);
    setPickedHost(host);
  };

  useEffect(() => () => setPendingConnectionError(null), []);

=======
>>>>>>> upstream-sync-a9418a120-upstream-renamed
  const handleScanPress = async () => {
    const permission = await requestCameraPermission();
    if (permission.granted) {
      setScanComplete(false);
      return;
    }
    if (permission.canAskAgain) return;
    Dialog.alert(
      "Camera access needed",
      "Camera access was denied for this app. Open Settings to enable it.",
      [
        { text: "Cancel", style: "cancel" },
        { text: "Open Settings", onPress: () => void Linking.openSettings() },
      ],
    );
  };

  const handleQrScan = ({ data }: { readonly data: string }) => {
    if (scannerLocked) {
      return;
    }

    setScannerLocked(true);

    try {
      const pairingUrl = extractPairingUrlFromQrPayload(data);
      const { host, code } = parsePairingUrl(pairingUrl);
      setHostInput(host);
      setCodeInput(code);
      onChangeConnectionPairingUrl(pairingUrl);
      setScanComplete(true);
      setScannerLocked(false);
    } catch (error) {
      void Haptics.notificationAsync(Haptics.NotificationFeedbackType.Error);
      Dialog.alert(
        "Invalid QR code",
        error instanceof Error ? error.message : "Scanned QR code was not recognized.",
      );
      setTimeout(() => {
        setScannerLocked(false);
      }, 600);
    }
  };

  const handleSubmit = async () => {
    const pairingUrl = buildPairingUrl(hostInput, codeInput);
    setOwnAttempt(true);
    setSubmitError(null);
    setIsSubmitting(true);
    onChangeConnectionPairingUrl(pairingUrl);
    const outcome = await onConnectPress(pairingUrl, routeFor);
    setIsSubmitting(false);
    setSubmitError(outcome.error);
    void Haptics.notificationAsync(
      outcome.ok
        ? Haptics.NotificationFeedbackType.Success
        : Haptics.NotificationFeedbackType.Error,
    );
    if (outcome.ok) {
      // Replacing with Home would nest it inside any sheet below; return to the opener.
      if (!navigation.canGoBack()) {
        navigation.dispatch(StackActions.replace("Home"));
      } else {
        // Added from the Settings list, the new environment shows on Environments.
        leaveSettingsPage(navigation, workspaceHasColumns(), "SettingsEnvironments");
      }
    }
  };

<<<<<<< HEAD
  const handleApprovedCredential = (credential: string) => {
    void connectAndClose(buildPairingUrl(hostInput, credential));
  };

  const handleSubmit = async () => {
    await connectAndClose(buildPairingUrl(hostInput, codeInput));
  };

  useEffect(() => {
    if (!shouldAutoConnect || attemptedAutoConnectRef.current === routePairingUrl) {
      return;
    }

    attemptedAutoConnectRef.current = routePairingUrl;
    void connectAndClose(routePairingUrl);
  }, [connectAndClose, routePairingUrl, shouldAutoConnect]);

=======
>>>>>>> upstream-sync-a9418a120-upstream-renamed
  return (
    <SettingsScreen
      formSheet={routeName === "ConnectionsNew"}
      title="Add environment"
      actions={[
        {
          accessibilityLabel: connecting ? "Connecting" : "Add environment",
          loading: connecting,
          icon: "checkmark",
          tintColor: headerIconColor,
          disabled: connectDisabled,
          onPress: () => {
            void handleSubmit();
          },
        },
      ]}
    >
      <ScrollView
        nestedScrollEnabled
        contentInsetAdjustmentBehavior="automatic"
        keyboardShouldPersistTaps="handled"
        showsVerticalScrollIndicator={false}
        className="flex-1"
        contentInset={{ bottom: Math.max(insets.bottom, 18) + 18 }}
        contentContainerStyle={{
          paddingHorizontal: 16,
          paddingTop: 4,
        }}
      >
        <View collapsable={false} className="gap-6.5">
          <PairingScanCard
            cameraActive={cameraPermission?.granted === true && screenFocused && !scanComplete}
            onScan={handleQrScan}
            onScanPress={() => {
              void handleScanPress();
            }}
          />

          <View collapsable={false} className="gap-2">
            <Text className="px-4 text-sm font-infinitus-medium text-foreground-muted">
              Or enter it
            </Text>
            <InfinitusNearbyServers onPick={handleNearbyPick} />
            <View
              collapsable={false}
              className={cn(
                "overflow-hidden rounded-[26px] border-continuous border bg-grouped-card",
                pairingConnectionError ? "border-danger-foreground" : "border-transparent",
              )}
            >
              <PairingInputRow
                label="Address"
                keyboardType="url"
                placeholder="192.168.1.100:3773"
                value={hostInput}
                onChangeText={handleHostChange}
              />
              <View className="ml-4 border-t border-border-subtle" />
              <PairingInputRow
                label="Code"
                placeholder="Pairing code"
                returnKeyType="go"
                value={codeInput}
                onChangeText={handleCodeChange}
                onSubmitEditing={() => {
                  if (!connectDisabled) void handleSubmit();
                }}
              />
            </View>
            <InfinitusAskToApprove
              host={hostInput}
              disabled={isSubmitting}
              onCredential={handleApprovedCredential}
            />
            <Text
              accessibilityLiveRegion="polite"
              className={cn(
                "px-4 text-sm leading-normal",
                pairingConnectionError ? "text-danger-foreground" : "text-foreground-muted",
              )}
            >
              {pairingConnectionError ??
                (needsCode
                  ? PICKED_HOST_HINT
                  : "For machines on your local network or tailnet. The machine keeps its own provider credentials.")}
            </Text>
          </View>

          {hasCloudPublicConfig() ? <InfinitusConnectSection /> : null}
        </View>
      </ScrollView>
    </SettingsScreen>
  );
}

const SCAN_CARD_HEIGHT = 250;
const SCAN_RETICLE_SIZE = 150;
const SCAN_RETICLE_TOP = 36;
const SCAN_RETICLE_RADIUS = 28;

function PairingScanCard(props: {
  readonly cameraActive: boolean;
  readonly onScan: (result: { readonly data: string }) => void;
  readonly onScanPress: () => void;
}) {
  const light = useAppearancePreferences().themeAppearance === "light";
  return (
    <Pressable
      accessibilityRole={props.cameraActive ? undefined : "button"}
      accessibilityLabel={props.cameraActive ? undefined : "Scan QR code"}
      disabled={props.cameraActive}
      onPress={props.onScanPress}
      className={cn(
        "overflow-hidden rounded-[26px] border-continuous",
        light ? "bg-white" : "bg-black",
      )}
      style={{ height: SCAN_CARD_HEIGHT }}
    >
      <Svg accessibilityElementsHidden height="100%" style={StyleSheet.absoluteFill} width="100%">
        <Defs>
          <RadialGradient id="pairing-scan-backdrop" cx="50%" cy="50%" r="50%">
            <Stop offset="0%" stopColor={light ? "#f4f4f5" : "#2e2e2e"} />
            <Stop offset="100%" stopColor={light ? "#d9d9dc" : "#0e0e0e"} />
          </RadialGradient>
        </Defs>
        <Rect fill="url(#pairing-scan-backdrop)" height="100%" width="100%" />
      </Svg>

      {props.cameraActive ? (
        <>
          <CameraView
            active
            barcodeScannerSettings={{ barcodeTypes: ["qr"] }}
            onBarcodeScanned={props.onScan}
            style={StyleSheet.absoluteFill}
          />
          <FrostedCutout
            cutoutTop={SCAN_RETICLE_TOP}
            cutoutWidth={SCAN_RETICLE_SIZE}
            cutoutHeight={SCAN_RETICLE_SIZE}
            cutoutRadius={SCAN_RETICLE_RADIUS}
            appearance={light ? "light" : "dark"}
          />
        </>
      ) : null}

      <View
        pointerEvents="none"
        className="absolute inset-x-0 items-center gap-3.5"
        style={{ top: SCAN_RETICLE_TOP }}
      >
        <View
          className={cn(
            "items-center justify-center gap-2 border-continuous border-[3px]",
            light ? "border-black/70" : "border-white/80",
          )}
          style={{
            borderRadius: SCAN_RETICLE_RADIUS,
            height: SCAN_RETICLE_SIZE,
            width: SCAN_RETICLE_SIZE,
          }}
        >
          {props.cameraActive ? null : (
            <>
              <SymbolView
                name="qrcode.viewfinder"
                size={44}
                tintColorClassName={light ? "accent-black/60" : "accent-white/70"}
                type="monochrome"
                weight="light"
              />
              <Text
                className={cn(
                  "font-infinitus-medium text-sm",
                  light ? "text-black/70" : "text-white/80",
                )}
              >
                Tap to scan
              </Text>
            </>
          )}
        </View>
        <Text className={cn("text-center text-sm", light ? "text-black/70" : "text-white/80")}>
          Scan the code from t3 pair or desktop Connections settings
        </Text>
      </View>
    </Pressable>
  );
}

function InfinitusConnectSection() {
  const { isLoaded, isSignedIn } = useAuth({ treatPendingAsSignedOut: false });
  const navigation = useNavigation();
  const { connectedEnvironments, onSetEnvironmentEnabled, onRemoveEnvironmentPress } =
    useRemoteConnections();
  const { connectedCloudEnvironments } = splitEnvironmentSections({
    connectedEnvironments,
    cloudEnvironments: null,
  });

  return (
    <View collapsable={false} className="gap-2">
      <Text className="px-4 text-sm font-infinitus-medium text-foreground-muted">
        Or use the managed relay
      </Text>
      {isSignedIn ? (
        <CloudEnvironmentRows
          connectedCloudEnvironments={connectedCloudEnvironments}
          onSetEnvironmentEnabled={onSetEnvironmentEnabled}
          onRemoveEnvironment={onRemoveEnvironmentPress}
          showHeader={false}
        />
      ) : (
        <ListRow
          label={`Sign in to ${CONNECT_NAME}`}
          description="Reach your machines from anywhere, no network setup."
          disabled={!isLoaded}
          onPress={() => navigation.navigate("SettingsAuth")}
        />
      )}
    </View>
  );
}

function PairingInputRow({
  label,
  ...inputProps
}: Omit<AppTextInputProps, "accessibilityLabel" | "className"> & {
  readonly label: string;
}) {
  return (
    <View collapsable={false} className="h-13 flex-row items-center gap-3 px-4">
      <Text
        accessibilityElementsHidden
        importantForAccessibility="no-hide-descendants"
        className="w-20 text-base leading-[23px] text-foreground-muted"
      >
        {label}
      </Text>
      <AppTextInput
        {...inputProps}
        accessibilityLabel={label}
        autoCapitalize="none"
        autoCorrect={false}
        className="min-h-0 flex-1 rounded-none border-0 bg-transparent p-0 text-base leading-[23px]"
      />
    </View>
  );
}
