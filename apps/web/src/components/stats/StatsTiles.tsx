import type { StatsTile, StatsTileGroup } from "@t3tools/client-runtime/state/infinitusStats";

/** A tile group: the section title, then tiles in a responsive grid. */
export function StatsTileGroupView({ group }: { readonly group: StatsTileGroup }) {
  return (
    <section className="flex flex-col gap-2">
      <h2 className="font-medium text-foreground text-sm">{group.id}</h2>
      <div className="grid grid-cols-[repeat(auto-fill,minmax(150px,1fr))] gap-2">
        {group.tiles.map((tile) => (
          <StatsTileView key={tile.id} tile={tile} />
        ))}
      </div>
    </section>
  );
}

/** Value, delta vs the previous period, sparkline of the days. */
function StatsTileView({ tile }: { readonly tile: StatsTile }) {
  const deltaClass =
    tile.delta === null
      ? ""
      : tile.delta.startsWith("+")
        ? "text-success-foreground"
        : tile.delta.startsWith("−")
          ? "text-warning-foreground"
          : "text-muted-foreground";
  return (
    <div className="flex flex-col gap-1 rounded-lg border p-3">
      <p className="text-muted-foreground text-xs">{tile.id}</p>
      <p className="flex items-baseline gap-2">
        <span className="font-semibold text-foreground text-lg tabular-nums">{tile.value}</span>
        {tile.delta === null ? null : (
          <span className={`text-[11px] tabular-nums ${deltaClass}`}>{tile.delta}</span>
        )}
      </p>
      <Sparkline series={tile.series} />
    </div>
  );
}

/** The day series as one polyline; flat when every point is zero. */
function Sparkline({ series }: { readonly series: ReadonlyArray<number> }) {
  if (series.length < 2) return <div className="h-6" aria-hidden />;
  const width = 96;
  const height = 24;
  const max = Math.max(...series, 0);
  const step = width / (series.length - 1);
  const points = series
    .map((value, index) => {
      const y = max === 0 ? height - 1 : height - 1 - (value / max) * (height - 2);
      return `${(index * step).toFixed(1)},${y.toFixed(1)}`;
    })
    .join(" ");
  return (
    <svg
      viewBox={`0 0 ${width} ${height}`}
      className="h-6 w-full text-primary"
      preserveAspectRatio="none"
      aria-hidden
    >
      <polyline points={points} fill="none" stroke="currentColor" strokeWidth="1.5" />
    </svg>
  );
}
