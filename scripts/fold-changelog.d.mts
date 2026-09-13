export declare const SURFACES: readonly string[];
export declare function foldChangelog(
  changelog: string,
  fragments: ReadonlyArray<readonly [string, string]>,
  version: string,
): { text: string; warnings: string[] };
export declare function readFragments(dir: string): Array<[string, string]>;
