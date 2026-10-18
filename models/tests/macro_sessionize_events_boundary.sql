{{ config(materialized='ephemeral') }}

WITH annotated AS (
  {{ dbt_event_patterns.sessionize_events(
      relation=ref('macro_sessionize_events_boundary_data'),
      event_ts='event_at',
      partition_by=['user_id'],
      scope_by=['event_type'],
      boundary_key='DATE(event_at)',
      inactivity_seconds=5,
      tie_breaker=['event_id']
  ) }}
)
SELECT
  event_id,
  session_start_ts,
  session_end_ts,
  session_event_count,
  session_event_seq_num_asc,
  session_event_seq_num_desc,
  LENGTH(session_id) AS session_id_length
FROM annotated
