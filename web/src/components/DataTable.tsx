import type { ReactNode } from "react";

export interface Column<T> {
  header: string;
  render: (row: T) => ReactNode;
  /** When true, cell wraps instead of ellipsis-clipping. */
  wrap?: boolean;
}

export interface DataTableProps<T> {
  columns: Column<T>[];
  rows: T[];
  keyFor: (row: T, index: number) => string;
  loading: boolean;
  error: string | null;
  emptyLabel?: string;
}

export function DataTable<T>({
  columns,
  rows,
  keyFor,
  loading,
  error,
  emptyLabel = "No rows",
}: DataTableProps<T>) {
  if (error) {
    return <p className="error-text">Failed to load: {error}</p>;
  }

  return (
    <table className="data-table">
      <thead>
        <tr>
          {columns.map((col) => (
            <th key={col.header}>{col.header}</th>
          ))}
        </tr>
      </thead>
      <tbody>
        {rows.length === 0 && !loading ? (
          <tr>
            <td colSpan={columns.length} className="muted">
              {emptyLabel}
            </td>
          </tr>
        ) : (
          rows.map((row, index) => (
            <tr key={keyFor(row, index)}>
              {columns.map((col) => (
                <td key={col.header} className={col.wrap ? "cell-wrap" : "cell-clip"}>
                  {col.render(row)}
                </td>
              ))}
            </tr>
          ))
        )}
      </tbody>
    </table>
  );
}
