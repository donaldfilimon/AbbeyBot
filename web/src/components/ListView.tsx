import { useEffect, useState } from "react";
import { type Column, DataTable } from "./DataTable";

const INITIAL_LIMIT = 100;
const LIMIT_STEP = 100;

export interface ListViewProps<T> {
  title: string;
  columns: Column<T>[];
  keyFor: (row: T, index: number) => string;
  fetcher: (limit: number) => Promise<T[]>;
}

/** One table view backed by a `GET /api/<x>?limit=` endpoint with a manual
 * "load more" control that bumps the limit and refetches (no real
 * pagination on the server). */
export function ListView<T>({ title, columns, keyFor, fetcher }: ListViewProps<T>) {
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

  return (
    <section>
      <div className="list-header">
        <h2>{title}</h2>
        <span className="muted">
          {loading ? "Loading…" : `${rows.length} row(s), limit ${limit}`}
        </span>
      </div>
      <DataTable
        columns={columns}
        rows={rows}
        keyFor={keyFor}
        loading={loading}
        error={error}
      />
      <button
        type="button"
        className="load-more"
        disabled={loading || rows.length < limit}
        onClick={() => setLimit((current) => current + LIMIT_STEP)}
      >
        Load more
      </button>
    </section>
  );
}
