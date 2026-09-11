/**
 * Deep links (#270 D): `new?project=…` names a project by id, by title, or by
 * the last segment of its workspace root — a link is typed or pasted, so the
 * folder name is the handle people actually know. Titles and folders match
 * case-insensitively; the first project in list order wins a tie.
 */
export interface DeepLinkProjectCandidate {
  readonly id: string;
  readonly title: string;
  readonly workspaceRoot: string;
}

export function workspaceRootBasename(workspaceRoot: string): string {
  const segments = workspaceRoot.split(/[\\/]+/).filter((segment) => segment.length > 0);
  return segments[segments.length - 1] ?? "";
}

export function resolveDeepLinkProject<T extends DeepLinkProjectCandidate>(
  projects: ReadonlyArray<T>,
  key: string,
): T | null {
  const wanted = key.trim();
  if (wanted.length === 0) return null;
  const folded = wanted.toLowerCase();
  return (
    projects.find((project) => project.id === wanted) ??
    projects.find((project) => project.title.trim().toLowerCase() === folded) ??
    projects.find(
      (project) => workspaceRootBasename(project.workspaceRoot).toLowerCase() === folded,
    ) ??
    null
  );
}
