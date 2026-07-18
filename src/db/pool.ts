import { Pool, QueryResult, QueryResultRow } from "pg";

export type { Pool };

export async function query<T extends QueryResultRow = QueryResultRow>(
  pool: Pool,
  text: string,
  params: unknown[] = []
): Promise<QueryResult<T>> {
  return pool.query<T>(text, params as never[]);
}
