{{ config(materialized='ephemeral') }}

WITH original AS (
  {{ dbt_event_patterns.sessionize_events(
      relation=ref('macro_sessionize_events_data'),
      event_ts='event_at',
      partition_by=['user_id'],
      scope_by=['event_type'],
      inactivity_seconds=5,
      tie_breaker=['event_id']
  ) }}
),
reordered_source AS (
  SELECT *
  FROM {{ ref('macro_sessionize_events_data') }}
  ORDER BY event_id DESC
),
reordered AS (
  {{ dbt_event_patterns.sessionize_events(
      relation='reordered_source',
      event_ts='event_at',
      partition_by=['user_id'],
      scope_by=['event_type'],
      inactivity_seconds=5,
      tie_breaker=['event_id']
  ) }}
)
SELECT
  original.event_id,
  original.session_id = reordered.session_id AS same_session_id,
  original.session_event_seq_num_asc = reordered.session_event_seq_num_asc AS same_asc
FROM original
JOIN reordered USING (event_id)
