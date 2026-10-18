-- Compile with: dbt compile --select sessionize_events_example
-- Events a, b, and c form one session; d and e form another.
-- The exact 5-minute gap stays in a session; the 6-minute gap starts a new one.

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
  {{ dbt_event_patterns.sessionize_events(
      relation='events',
      event_ts='event_at',
      partition_by=['user_id'],
      inactivity_seconds=300,
      tie_breaker=['event_id'],
      indent=2
  ) }}
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
