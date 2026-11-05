import { builtInSecretProviderDefinitions } from "@infinitus/secret-provider-definitions/registry";
import * as OnePasswordDriver from "@infinitus/secret-provider-onepassword/server/driver";

/** In the shared registry's order. */
export const BUILT_IN_SECRET_PROVIDER_DRIVER_LIST = [OnePasswordDriver.driver] as const;

export const secretProviderDefinitions = builtInSecretProviderDefinitions;
