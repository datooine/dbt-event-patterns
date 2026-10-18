{{ config(materialized='ephemeral') }}

WITH annotated AS (
  {{ dbt_event_patterns.sessionize_events(
      relation=ref('macro_sessionize_events_data'),
      event_ts='event_at',
      partition_by=['user_id'],
      scope_by=['event_type'],
      inactivity_seconds=5,
      tie_breaker=['event_id'],
      output_prefix='query_burst_'
  ) }}
)
SELECT
  event_id,
  query_burst_session_start_ts,
  query_burst_session_end_ts,
  query_burst_session_event_count,
  query_burst_session_event_seq_num_asc,
  query_burst_session_event_seq_num_desc,
  LENGTH(query_burst_session_id) AS query_burst_session_id_length
FROM annotated
