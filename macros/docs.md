{% docs __dbt_event_patterns__ %}
## dbt-event-patterns - Event Pattern Macros in SQL

Event streams lend themselves to many classic analyses and transformations:
sessionization, deduplication, funnels, retention, attribution, and more.
**dbt-event-patterns** aims to make these recurring patterns reusable through
SQL macros that run inside dbt and the warehouse.

This package starts with inactivity-based sessionization for BigQuery,
annotating each event with session metadata while preserving every input row
and column.
The public interface stays adapter-dispatched so other warehouses can be added
later without changing user code.
{% enddocs %}

{% docs sessionize_events %}
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

<pre><code class="language-jinja">&#123;&#123; dbt_event_patterns.sessionize_events(
    relation=ref('events'),
    event_ts='event_at',
    partition_by=['user_id'],
    inactivity_seconds=30,
    tie_breaker=['event_id']
) &#125;&#125;
</code></pre>

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

<pre><code class="language-jinja">&#123;&#123; dbt_event_patterns.sessionize_events(
    relation=ref('human_query_jobs'),
    event_ts='creation_time',
    partition_by=['project_id', 'user_email'],
    inactivity_seconds=5,
    tie_breaker=['job_id'],
    output_prefix='query_burst_'
) &#125;&#125;
</code></pre>

The prefixed invocation appends columns such as `query_burst_session_id` and
`query_burst_session_event_seq_num_asc`.

#### Scoped duplicate groups

Use `scope_by` to keep candidate duplicate streams independent:

<pre><code class="language-jinja">with annotated as (
    &#123;&#123; dbt_event_patterns.sessionize_events(
        relation=ref('raw_events'),
        event_ts='event_at',
        partition_by=['user_id'],
        scope_by=['event_type', 'order_id'],
        inactivity_seconds=5,
        tie_breaker=['ingested_at', 'source_row_number']
    ) &#125;&#125;
)
select *
from annotated
where session_event_seq_num_asc = 1
</code></pre>

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
{% enddocs %}

{% docs bigquery__sessionize_events %}
BigQuery implementation of `sessionize_events`. It is selected automatically by
dbt adapter dispatch and should not be called directly.
{% enddocs %}

{% docs default__sessionize_events %}
Default fallback implementation of `sessionize_events`. It raises a compiler
error for unsupported adapters.
{% enddocs %}
