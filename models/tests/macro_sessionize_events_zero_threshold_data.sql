{{ config(materialized='view') }}

-- Dummy schema definition for unit-test fixtures.
SELECT
  CAST(NULL AS STRING) AS event_id,
  CAST(NULL AS STRING) AS user_id,
  CAST(NULL AS TIMESTAMP) AS event_at
FROM UNNEST([1]) AS fixture_row
WHERE FALSE
