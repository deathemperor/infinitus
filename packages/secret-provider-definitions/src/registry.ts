import { makeSecretProviderDefinitionRegistry } from "@infinitus/secret-provider-core/shared/definition";
import * as OnePassword from "@infinitus/secret-provider-onepassword/shared/definition";

export const builtInSecretProviderDefinitions = makeSecretProviderDefinitionRegistry([
  OnePassword.definition,
]);
