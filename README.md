## dbt-event-patterns - Event Pattern Macros in SQL

### Why this project exists

Event streams lend themselves to many classic analyses and transformations:
sessionization, deduplication, funnels, retention, attribution, and more.
**dbt-event-patterns** aims to make these recurring patterns reusable through
SQL macros that run inside dbt and the warehouse.

This package starts with inactivity-based sessionization.

The initial implementation targets BigQuery. The public macro uses dbt adapter
dispatch so other adapters can be added later.

The declared dbt version range is `>=1.6.0,<3.0.0`, covering v1 and v2.

#### Installation

Add this package to your `packages.yml` and pull dependencies with `dbt deps`:

```yaml
packages:
  - package: datooine/dbt-event-patterns
    version: "~> 0.1"
```

```bash
dbt deps
```

### Available macros

- [`sessionize_events`](#sessionize_events) — Inactivity-based sessionization.

### sessionize_events

Annotates each input event with an inactivity-based session identifier, observed
session start/end timestamps, event count, and forward/reverse event positions.
The macro returns a SELECT query and preserves every original input column.

With a **5-minute inactivity threshold** (`inactivity_seconds=300`), where each
`|` represents an event in the same entity stream, with no boundary buckets:

```text
Time      10:00       10:03       10:08       10:14       10:16
Events    |---3 min---|---5 min---|---6 min---|---2 min---|
Sessions  [------ session 1 ------]          [ session 2 ]
          3 events                          2 events
```

The 5-minute gap stays within session 1. The 6-minute gap starts session 2.
The macro preserves every event and adds its session ID, start/end timestamps,
event count, and forward/reverse position within the session.

#### Basic usage

Once installed, call the macro through the `dbt_event_patterns` namespace:

```jinja
{{ dbt_event_patterns.sessionize_events(
    relation=ref('events'),
    event_ts='event_at',
    partition_by=['user_id'],
    inactivity_seconds=30,
    tie_breaker=['event_id']
) }}
```

Parameters:

| name | type | default | description |
| ---- | ---- | ------- | ----------- |
| `relation` | relation/sql | required | Source relation or CTE to annotate. |
| `event_ts` | sql | required | Expression yielding a non-null BigQuery `TIMESTAMP`. |
| `partition_by` | `array<sql>` | required | Non-empty list identifying independent event streams. |
| `inactivity_seconds` | integer | required | Non-negative inactivity threshold in seconds. |
| `tie_breaker` | `array<sql>` | required | Non-empty deterministic ordering expressions for equal timestamps. |
| `scope_by` | `array<sql>` | `[]` | Additional partition expressions, such as event type or order ID. |
| `boundary_key` | sql/null | `None` | Optional contiguous bucket expression, such as a local date or week-start date. |
| `output_prefix` | string | `''` | Optional prefix for appended output columns. |
| `indent` | integer | `0` | Indent the rendered SQL when embedding in larger queries. |

Output columns:

| column | BigQuery type | description |
| ------ | ------------- | ----------- |
| `{output_prefix}session_id` | STRING | Deterministic hash of effective partition and first-event identity. |
| `{output_prefix}session_start_ts` | TIMESTAMP | First observed event timestamp in the session. |
| `{output_prefix}session_end_ts` | TIMESTAMP | Last observed event timestamp in the session. |
| `{output_prefix}session_event_count` | INT64 | Number of rows in the session. |
| `{output_prefix}session_event_seq_num_asc` | INT64 | Position from session start, beginning at 1. |
| `{output_prefix}session_event_seq_num_desc` | INT64 | Position from session end, beginning at 1. |

Example:

```jinja
{{ dbt_event_patterns.sessionize_events(
    relation=ref('human_query_jobs'),
    event_ts='creation_time',
    partition_by=['project_id', 'user_email'],
    inactivity_seconds=5,
    tie_breaker=['job_id'],
    output_prefix='query_burst_'
) }}
```

The prefixed invocation appends columns such as `query_burst_session_id` and
`query_burst_session_event_seq_num_asc`.

#### Scoped duplicate groups

Use `scope_by` to keep candidate duplicate streams independent:

```jinja
with annotated as (
    {{ dbt_event_patterns.sessionize_events(
        relation=ref('raw_events'),
        event_ts='event_at',
        partition_by=['user_id'],
        scope_by=['event_type', 'order_id'],
        inactivity_seconds=5,
        tie_breaker=['ingested_at', 'source_row_number']
    ) }}
)
select *
from annotated
where session_event_seq_num_asc = 1
```

Scope expressions define candidate equivalence. The macro does not prove that
grouped events are duplicates.

#### Boundary buckets

`boundary_key` adds a contiguous bucket expression to the effective partition.
This prevents sessions from crossing bucket boundaries:

```jinja
boundary_key="DATE(event_at, 'Europe/Madrid')"
```

Other valid examples include:

```jinja
boundary_key="DATE_TRUNC(DATE(event_at, 'Europe/Madrid'), WEEK(MONDAY))"
boundary_key="DATE_TRUNC(DATE(event_at, 'Europe/Madrid'), MONTH)"
```

Use complete bucket values, not recurring values such as day-of-month or month
number. Observed session start and end timestamps remain event timestamps, not
bucket edges.

#### Semantics and contracts

Within each effective partition, events are sorted by `event_ts ASC`, then each
tie breaker expression `ASC NULLS FIRST`. A later event starts a new session
only when its timestamp is strictly greater than the previous timestamp plus
`inactivity_seconds`. Events exactly at the threshold stay in the existing
session, and identical timestamps stay together even when the threshold is zero.

The caller is responsible for input data tests:

- `event_ts` must be non-null.
- `boundary_key` must be non-null when supplied.
- The effective partition plus full ordering tuple must be unique.
- Input columns must not collide with output names or the reserved `__dep_`
  internal prefix. For physical relations, set
  `sessionize_events_validate_column_collisions: true` to enable warehouse-backed
  compile-time collision checks.

The macro is a pure SQL transformation. It does not manage watermarks, fetch
history, finalize sessions, or perform incremental writes. For results matching
a full-history run, pass all rows belonging to the sessions being recomputed. If
`boundary_key` is supplied, complete affected buckets can be processed
independently.

The session ID is a deterministic BigQuery hash over the effective partition and
the first event's timestamp/tie-breaker tuple. IDs are stable for unchanged
input and configuration, but can change when earlier anchors are inserted,
sessions are bridged, identity logic changes, or serialization changes.

### Example analysis

The self-contained [sessionize_events_example.sql](analyses/sessionize_events_example.sql)
uses five events from one user with a five-minute inactivity threshold:

```jinja
{{ dbt_event_patterns.sessionize_events(
    relation='events',
    event_ts='event_at',
    partition_by=['user_id'],
    inactivity_seconds=300,
    tie_breaker=['event_id']
) }}
```

The analysis returns the following rows. All timestamps are on 2026-01-01 UTC;
only the times are shown. S1 and S2 stand for the generated 64-character session
hashes. The position columns correspond to `session_event_seq_num_asc` and
`session_event_seq_num_desc`.

| Event | User | Event time | Session | Session start | Session end | Event count | Position ↑ | Position ↓ |
| ----- | ---- | ---------- | ------- | ------------- | ----------- | ----------: | ---------: | ---------: |
| a | user_1 | 10:00 | S1 | 10:00 | 10:08 | 3 | 1 | 3 |
| b | user_1 | 10:03 | S1 | 10:00 | 10:08 | 3 | 2 | 2 |
| c | user_1 | 10:08 | S1 | 10:00 | 10:08 | 3 | 3 | 1 |
| d | user_1 | 10:14 | S2 | 10:14 | 10:16 | 2 | 1 | 2 |
| e | user_1 | 10:16 | S2 | 10:14 | 10:16 | 2 | 2 | 1 |

The five-minute gap between b and c keeps them in the same session. The
six-minute gap between c and d starts a second session. Every input event is
preserved, with metadata ready for further analysis or aggregation.

<details>
<summary>Compiled BigQuery SQL</summary>

```sql
WITH events AS (
  -- Replace this sample input with your own event relation or CTE.
  SELECT 'a' AS event_id, 'user_1' AS user_id, TIMESTAMP('2026-01-01 10:00:00+00') AS event_at
  UNION ALL
  SELECT 'b', 'user_1', TIMESTAMP('2026-01-01 10:03:00+00')
  UNION ALL
  SELECT 'c', 'user_1', TIMESTAMP('2026-01-01 10:08:00+00')
  UNION ALL
  SELECT 'd', 'user_1', TIMESTAMP('2026-01-01 10:14:00+00')
  UNION ALL
  SELECT 'e', 'user_1', TIMESTAMP('2026-01-01 10:16:00+00')
),
sessionized AS (

  WITH __dep_source AS (
    SELECT
      src.*,
      event_at AS __dep_event_ts,
      user_id AS __dep_partition_1,
      event_id AS __dep_tie_1
    FROM events AS src
  ),
  __dep_lagged AS (
    SELECT
      __dep_source.*,
      LAG(__dep_event_ts) OVER (
        PARTITION BY __dep_partition_1
        ORDER BY __dep_event_ts ASC, __dep_tie_1 ASC NULLS FIRST
      ) AS __dep_previous_event_ts
    FROM __dep_source
  ),
  __dep_session_starts AS (
    SELECT
      __dep_lagged.*,
      CASE
        WHEN __dep_previous_event_ts IS NULL THEN 1
        WHEN __dep_event_ts > TIMESTAMP_ADD(__dep_previous_event_ts, INTERVAL 300 SECOND) THEN 1
        ELSE 0
      END AS __dep_is_session_start
    FROM __dep_lagged
  ),
  __dep_numbered AS (
    SELECT
      __dep_session_starts.*,
      SUM(__dep_is_session_start) OVER (
        PARTITION BY __dep_partition_1
        ORDER BY __dep_event_ts ASC, __dep_tie_1 ASC NULLS FIRST
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
      ) AS __dep_session_ordinal
    FROM __dep_session_starts
  ),
  __dep_anchored AS (
    SELECT
      __dep_numbered.*,
      FIRST_VALUE(__dep_event_ts) OVER (
        PARTITION BY __dep_partition_1, __dep_session_ordinal
        ORDER BY __dep_event_ts ASC, __dep_tie_1 ASC NULLS FIRST
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
      ) AS __dep_session_start_ts,

      FIRST_VALUE(__dep_tie_1) OVER (
        PARTITION BY __dep_partition_1, __dep_session_ordinal
        ORDER BY __dep_event_ts ASC, __dep_tie_1 ASC NULLS FIRST
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
      ) AS __dep_session_start_tie_1,

      MIN(__dep_event_ts) OVER (
        PARTITION BY __dep_partition_1, __dep_session_ordinal
      ) AS __dep_session_min_ts,
      MAX(__dep_event_ts) OVER (
        PARTITION BY __dep_partition_1, __dep_session_ordinal
      ) AS __dep_session_max_ts,
      COUNT(*) OVER (
        PARTITION BY __dep_partition_1, __dep_session_ordinal
      ) AS __dep_session_event_count,
      ROW_NUMBER() OVER (
        PARTITION BY __dep_partition_1, __dep_session_ordinal
        ORDER BY __dep_event_ts ASC, __dep_tie_1 ASC NULLS FIRST
      ) AS __dep_session_event_seq_num_asc
    FROM __dep_numbered
  ),
  __dep_final AS (
    SELECT
      * EXCEPT(
        __dep_event_ts,
        __dep_partition_1,
        __dep_tie_1,
        __dep_previous_event_ts,
        __dep_is_session_start,
        __dep_session_ordinal,
        __dep_session_start_ts,

        __dep_session_start_tie_1,

        __dep_session_min_ts,
        __dep_session_max_ts,
        __dep_session_event_count,
        __dep_session_event_seq_num_asc
      ),
      TO_HEX(SHA256(TO_JSON_STRING(STRUCT(
        STRUCT(__dep_partition_1 AS p1) AS effective_partition,
        STRUCT(__dep_session_start_ts AS session_start_ts, __dep_session_start_tie_1 AS tie_1) AS first_event
      )))) AS `session_id`,
      __dep_session_min_ts AS `session_start_ts`,
      __dep_session_max_ts AS `session_end_ts`,
      __dep_session_event_count AS `session_event_count`,
      __dep_session_event_seq_num_asc AS `session_event_seq_num_asc`,
      __dep_session_event_count - __dep_session_event_seq_num_asc + 1 AS `session_event_seq_num_desc`
    FROM __dep_anchored
  )
  SELECT *
  FROM __dep_final

)
SELECT
  event_id,
  user_id,
  event_at,
  session_id,
  session_start_ts,
  session_end_ts,
  session_event_count,
  session_event_seq_num_asc,
  session_event_seq_num_desc
FROM sessionized
ORDER BY user_id, event_at, event_id
```

</details>

### Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for local setup, dbt v1/v2 development,
unit tests, and running CI locally with act.
