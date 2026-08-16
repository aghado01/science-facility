# Nushell: Data Analysis & External Queries

## HTTP Requests (Auto-Parsed)
- `http get https://api.github.com/repos/nushell/nushell | get stargazers_count`
- `http post -t application/json https://httpbin.org/post { key: "val" }`

## Aggregations & Grouping
- `open metrics.json | group-by status | transpose status rows | insert count { $in.rows | length }`
- `open data.csv | get latency | math avg` (`math min`, `math max`, `math sum`, `math stddev`)

## Polars DataFrames (High Volume)
- `polars open large_data.parquet | polars select [col_a col_b] | polars filter (polars col col_a > 100) | polars collect`

## SQLite Inline Queries
- `open db.sqlite | query db "SELECT name, count(*) FROM logs GROUP BY name"`
