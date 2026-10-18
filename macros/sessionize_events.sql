{# dbt_event_patterns: PUBLIC PROXY MACRO (no implementation here)
   Use adapter dispatch to call the adapter-specific variant. #}

{% macro sessionize_events(
    relation,
    event_ts,
    partition_by,
    inactivity_seconds,
    tie_breaker,
    scope_by=[],
    boundary_key=None,
    output_prefix='',
    indent=0
) %}
  {{ return(
      adapter.dispatch('sessionize_events', 'dbt_event_patterns')(
          relation=relation,
          event_ts=event_ts,
          partition_by=partition_by,
          inactivity_seconds=inactivity_seconds,
          tie_breaker=tie_breaker,
          scope_by=scope_by,
          boundary_key=boundary_key,
          output_prefix=output_prefix
      ) | indent(indent | int, True)
  ) }}
{% endmacro %}

{% macro default__sessionize_events(
    relation,
    event_ts,
    partition_by,
    inactivity_seconds,
    tie_breaker,
    scope_by=[],
    boundary_key=None,
    output_prefix='',
    indent=0
) %}
  {# Package Hub parses with a placeholder adapter and execute=False. #}
  {% if execute %}
    {{ exceptions.raise_compiler_error("dbt_event_patterns: sessionize_events not implemented for adapter '" ~ target.type ~ "'. Supported: bigquery.") }}
  {% endif %}
  {{ return('') }}
{% endmacro %}
