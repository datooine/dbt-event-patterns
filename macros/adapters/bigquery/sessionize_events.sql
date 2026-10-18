{% macro bigquery__sessionize_events(
    relation,
    event_ts,
    partition_by,
    inactivity_seconds,
    tie_breaker,
    scope_by=[],
    boundary_key=None,
    output_prefix=''
) %}
  {% set macro_name = 'dbt_event_patterns.sessionize_events' %}

  {% if relation is none %}
    {{ exceptions.raise_compiler_error(macro_name ~ ": relation is required.") }}
  {% endif %}
  {% if event_ts is not string or event_ts | trim == '' %}
    {{ exceptions.raise_compiler_error(macro_name ~ ": event_ts must be a non-empty SQL expression string.") }}
  {% endif %}
  {% if partition_by is string or partition_by is not iterable or partition_by | length == 0 %}
    {{ exceptions.raise_compiler_error(macro_name ~ ": partition_by must be a non-empty list of SQL expression strings.") }}
  {% endif %}
  {% if tie_breaker is string or tie_breaker is not iterable or tie_breaker | length == 0 %}
    {{ exceptions.raise_compiler_error(macro_name ~ ": tie_breaker must be a non-empty list of SQL expression strings.") }}
  {% endif %}
  {% if scope_by is none %}
    {% set scope_by = [] %}
  {% endif %}
  {% if scope_by is string or scope_by is not iterable %}
    {{ exceptions.raise_compiler_error(macro_name ~ ": scope_by must be a list of SQL expression strings.") }}
  {% endif %}
  {% if inactivity_seconds is boolean or inactivity_seconds is not number or inactivity_seconds != (inactivity_seconds | int) or inactivity_seconds < 0 %}
    {{ exceptions.raise_compiler_error(macro_name ~ ": inactivity_seconds must be a non-negative integer literal.") }}
  {% endif %}
  {% if boundary_key is not none and (boundary_key is not string or boundary_key | trim == '') %}
    {{ exceptions.raise_compiler_error(macro_name ~ ": boundary_key must be none or a non-empty SQL expression string.") }}
  {% endif %}
  {% if output_prefix is not string %}
    {{ exceptions.raise_compiler_error(macro_name ~ ": output_prefix must be a string.") }}
  {% endif %}
  {% if output_prefix | length > 0 %}
    {% if not modules.re.match('^[A-Za-z_][A-Za-z0-9_]*$', output_prefix) %}
      {{ exceptions.raise_compiler_error(macro_name ~ ": output_prefix must be empty or a valid unquoted BigQuery identifier prefix, such as 'query_burst_'. Got '" ~ output_prefix ~ "'.") }}
    {% endif %}
  {% endif %}

  {% for expr in partition_by %}
    {% if expr is not string or expr | trim == '' %}
      {{ exceptions.raise_compiler_error(macro_name ~ ": partition_by entries must be non-empty SQL expression strings.") }}
    {% endif %}
  {% endfor %}
  {% for expr in scope_by %}
    {% if expr is not string or expr | trim == '' %}
      {{ exceptions.raise_compiler_error(macro_name ~ ": scope_by entries must be non-empty SQL expression strings.") }}
    {% endif %}
  {% endfor %}
  {% for expr in tie_breaker %}
    {% if expr is not string or expr | trim == '' %}
      {{ exceptions.raise_compiler_error(macro_name ~ ": tie_breaker entries must be non-empty SQL expression strings.") }}
    {% endif %}
  {% endfor %}

  {% set public_suffixes = [
      'session_id',
      'session_start_ts',
      'session_end_ts',
      'session_event_count',
      'session_event_seq_num_asc',
      'session_event_seq_num_desc'
  ] %}
  {% set output_columns = [] %}
  {% for suffix in public_suffixes %}
    {% do output_columns.append(output_prefix ~ suffix) %}
  {% endfor %}
  {% if output_columns | unique | list | length != output_columns | length %}
    {{ exceptions.raise_compiler_error(macro_name ~ ": output_prefix creates duplicate output column names.") }}
  {% endif %}

  {% if var('sessionize_events_validate_column_collisions', false) and execute and relation is not string and relation.type is defined and relation.type in ['table', 'view'] %}
    {% set relation_columns = adapter.get_columns_in_relation(relation) %}
    {% set existing_names = [] %}
    {% for column in relation_columns %}
      {% do existing_names.append(column.name | lower) %}
    {% endfor %}
    {% for output_column in output_columns %}
      {% if output_column | lower in existing_names %}
        {{ exceptions.raise_compiler_error(macro_name ~ ": input relation already has column '" ~ output_column ~ "'. Use output_prefix to avoid collisions.") }}
      {% endif %}
    {% endfor %}
    {% for column_name in existing_names %}
      {% if column_name.startswith('__dep_') %}
        {{ exceptions.raise_compiler_error(macro_name ~ ": input relation contains reserved internal column prefix '__dep_'.") }}
      {% endif %}
    {% endfor %}
  {% endif %}

  {% set effective_partition_exprs = [] %}
  {% for expr in partition_by %}
    {% do effective_partition_exprs.append(expr) %}
  {% endfor %}
  {% for expr in scope_by %}
    {% do effective_partition_exprs.append(expr) %}
  {% endfor %}
  {% if boundary_key is not none %}
    {% do effective_partition_exprs.append(boundary_key) %}
  {% endif %}

  {% set partition_aliases = [] %}
  {% set partition_projection = [] %}
  {% set partition_refs = [] %}
  {% set partition_struct_fields = [] %}
  {% for expr in effective_partition_exprs %}
    {% set alias = '__dep_partition_' ~ loop.index %}
    {% do partition_aliases.append(alias) %}
    {% do partition_projection.append(expr ~ ' AS ' ~ alias) %}
    {% do partition_refs.append(alias) %}
    {% do partition_struct_fields.append(alias ~ ' AS p' ~ loop.index) %}
  {% endfor %}

  {% set tie_aliases = [] %}
  {% set tie_projection = [] %}
  {% set tie_order = [] %}
  {% set tie_struct_fields = [] %}
  {% for expr in tie_breaker %}
    {% set alias = '__dep_tie_' ~ loop.index %}
    {% do tie_aliases.append(alias) %}
    {% do tie_projection.append(expr ~ ' AS ' ~ alias) %}
    {% do tie_order.append(alias ~ ' ASC NULLS FIRST') %}
    {% do tie_struct_fields.append(alias ~ ' AS t' ~ loop.index) %}
  {% endfor %}

  {% set window_partition = partition_refs | join(', ') %}
  {% set order_by = ['__dep_event_ts ASC'] + tie_order %}
  {% set order_by_sql = order_by | join(', ') %}
  {% set anchor_fields = ['__dep_session_start_ts AS session_start_ts'] %}
  {% for alias in tie_aliases %}
    {% do anchor_fields.append('__dep_session_start_' ~ alias[6:] ~ ' AS ' ~ alias[6:]) %}
  {% endfor %}

  {% set sql %}
WITH __dep_source AS (
  SELECT
    src.*,
    {{ event_ts }} AS __dep_event_ts,
    {{ partition_projection | join(',\n    ') }},
    {{ tie_projection | join(',\n    ') }}
  FROM {{ relation }} AS src
),
__dep_lagged AS (
  SELECT
    __dep_source.*,
    LAG(__dep_event_ts) OVER (
      PARTITION BY {{ window_partition }}
      ORDER BY {{ order_by_sql }}
    ) AS __dep_previous_event_ts
  FROM __dep_source
),
__dep_session_starts AS (
  SELECT
    __dep_lagged.*,
    CASE
      WHEN __dep_previous_event_ts IS NULL THEN 1
      WHEN __dep_event_ts > TIMESTAMP_ADD(__dep_previous_event_ts, INTERVAL {{ inactivity_seconds | int }} SECOND) THEN 1
      ELSE 0
    END AS __dep_is_session_start
  FROM __dep_lagged
),
__dep_numbered AS (
  SELECT
    __dep_session_starts.*,
    SUM(__dep_is_session_start) OVER (
      PARTITION BY {{ window_partition }}
      ORDER BY {{ order_by_sql }}
      ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ) AS __dep_session_ordinal
  FROM __dep_session_starts
),
__dep_anchored AS (
  SELECT
    __dep_numbered.*,
    FIRST_VALUE(__dep_event_ts) OVER (
      PARTITION BY {{ window_partition }}, __dep_session_ordinal
      ORDER BY {{ order_by_sql }}
      ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS __dep_session_start_ts,
    {% for alias in tie_aliases %}
    FIRST_VALUE({{ alias }}) OVER (
      PARTITION BY {{ window_partition }}, __dep_session_ordinal
      ORDER BY {{ order_by_sql }}
      ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) AS __dep_session_start_{{ alias[6:] }},
    {% endfor %}
    MIN(__dep_event_ts) OVER (
      PARTITION BY {{ window_partition }}, __dep_session_ordinal
    ) AS __dep_session_min_ts,
    MAX(__dep_event_ts) OVER (
      PARTITION BY {{ window_partition }}, __dep_session_ordinal
    ) AS __dep_session_max_ts,
    COUNT(*) OVER (
      PARTITION BY {{ window_partition }}, __dep_session_ordinal
    ) AS __dep_session_event_count,
    ROW_NUMBER() OVER (
      PARTITION BY {{ window_partition }}, __dep_session_ordinal
      ORDER BY {{ order_by_sql }}
    ) AS __dep_session_event_seq_num_asc
  FROM __dep_numbered
),
__dep_final AS (
  SELECT
    * EXCEPT(
      __dep_event_ts,
      {{ partition_refs | join(',\n      ') }},
      {{ tie_aliases | join(',\n      ') }},
      __dep_previous_event_ts,
      __dep_is_session_start,
      __dep_session_ordinal,
      __dep_session_start_ts,
      {% for alias in tie_aliases %}
      __dep_session_start_{{ alias[6:] }},
      {% endfor %}
      __dep_session_min_ts,
      __dep_session_max_ts,
      __dep_session_event_count,
      __dep_session_event_seq_num_asc
    ),
    TO_HEX(SHA256(TO_JSON_STRING(STRUCT(
      STRUCT({{ partition_struct_fields | join(', ') }}) AS effective_partition,
      STRUCT({{ anchor_fields | join(', ') }}) AS first_event
    )))) AS {{ adapter.quote(output_columns[0]) }},
    __dep_session_min_ts AS {{ adapter.quote(output_columns[1]) }},
    __dep_session_max_ts AS {{ adapter.quote(output_columns[2]) }},
    __dep_session_event_count AS {{ adapter.quote(output_columns[3]) }},
    __dep_session_event_seq_num_asc AS {{ adapter.quote(output_columns[4]) }},
    __dep_session_event_count - __dep_session_event_seq_num_asc + 1 AS {{ adapter.quote(output_columns[5]) }}
  FROM __dep_anchored
)
SELECT *
FROM __dep_final
  {% endset %}

  {{ return(sql) }}
{% endmacro %}
