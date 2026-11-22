import type { AuthClientPresentationMetadata } from "@infinitus/contracts";
import * as Device from "expo-device";
import { Platform } from "react-native";
import { PRODUCT_NAME } from "@infinitus/shared/productName";

export function authClientMetadata(appVersion?: string): AuthClientPresentationMetadata {
  const osMajorVersion = Number.parseInt(Device.osVersion?.split(".")[0] ?? "", 10);
  const deviceModel = Device.modelName?.trim();

  return {
<<<<<<< HEAD
    label: `${PRODUCT_NAME} Mobile`,
=======
    // oxlint-disable-next-line t3code/no-untranslated-copy -- product name
    label: "T3 Code Mobile",
>>>>>>> upstream-sync-11224f63d2-upstream-renamed
    deviceType:
      Device.deviceType === Device.DeviceType.TABLET
        ? "tablet"
        : Device.deviceType === Device.DeviceType.PHONE
          ? "mobile"
          : "unknown",
    ...(Platform.OS === "ios" ? { os: "iOS" } : Platform.OS === "android" ? { os: "Android" } : {}),
    ...(Number.isFinite(osMajorVersion) && osMajorVersion > 0 ? { osMajorVersion } : {}),
    ...(deviceModel ? { deviceModel } : {}),
    surface: "mobile",
    ...(appVersion ? { appVersion } : {}),
  };
}
