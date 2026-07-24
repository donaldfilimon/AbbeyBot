import { useEffect, useState } from "react";
import { type Column, DataTable } from "./DataTable";

const INITIAL_LIMIT = 100;
const LIMIT_STEP = 100;
/** Server list endpoints clamp at 500 (see AbbeyServer routes). */
const MAX_LIMIT = 500;

export interface ListViewProps<T> {
  title: string;
  columns: Column<T>[];
  keyFor: (row: T, index: number) => string;
  fetcher: (limit: number) => Promise<T[]>;
  emptyLabel?: string;
}

/** One table view backed by a `GET /api/<x>?limit=` endpoint with a manual
 * "load more" control that bumps the limit and refetches (no real
 * pagination on the server). */
export function ListView<T>({ title, columns, keyFor, fetcher, emptyLabel }: ListViewProps<T>) {
  const [limit, setLimit] = useState(INITIAL_LIMIT);
  const [rows, setRows] = useState<T[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    fetcher(limit)
      .then((result) => {
        if (!cancelled) {
          setRows(result);
          setError(null);
        }
      })
      .catch((err) => {
        if (!cancelled) {
          setError(err instanceof Error ? err.message : String(err));
        }
      })
      .finally(() => {
        if (!cancelled) {
          setLoading(false);
        }
      });
    return () => {
      cancelled = true;
    };
  }, [limit, fetcher]);

  const atCap = limit >= MAX_LIMIT;
  const canLoadMore = !loading && rows.length >= limit && !atCap;

  return (
    <section>
      <div className="list-header">
        <h2>{title}</h2>
        <span className="muted">
          {loading ? "Loading…" : `${rows.length} row(s), limit ${limit}${atCap ? " (max)" : ""}`}
        </span>
      </div>
      <DataTable
        columns={columns}
        rows={rows}
        keyFor={keyFor}
        loading={loading}
        error={error}
        emptyLabel={emptyLabel}
      />
      <button
        type="button"
        className="load-more"
        disabled={!canLoadMore}
        onClick={() => setLimit((current) => Math.min(current + LIMIT_STEP, MAX_LIMIT))}
      >
        {atCap ? "Limit reached (500)" : "Load more"}
      </button>
      {atCap && (
        <p className="muted limit-note">Server list endpoints cap at 500 rows per request.</p>
      )}
    </section>
  );
}
