# Contributing

## Local setup

Use Python 3.12 or later and uv. Development and documentation generation use
dbt v2 by default:

```bash
uv sync --locked --extra dev
```

Configure a `dbt_event_patterns` profile in `~/.dbt/profiles.yml` with your
BigQuery project, development dataset, and location. For local OAuth, for example:

```yaml
dbt_event_patterns:
  target: dev
  outputs:
    dev:
      type: bigquery
      method: oauth
      project: your-gcp-project
      dataset: dbt_event_patterns_dev
      location: EU
      threads: 1
```

Authenticate with your Google account through Application Default Credentials:

```bash
gcloud auth application-default login
```

Local OAuth requires no service-account keyfile. Tests execute on BigQuery and
create fixture relations, so use a development dataset your account can write
to. The account also needs permission to run jobs and the **BigQuery Read Session
User** role (`roles/bigquery.readSessionUser`) on the project for dbt v2.

Set `DBT_PROFILES_DIR` or pass `--profiles-dir` to use a profile outside
`~/.dbt`. To reuse an existing profile with another name, pass
`--profile your_existing_profile`; this overrides `profile: dbt_event_patterns`
in `dbt_project.yml`.

## Compile and run tests

Run from the repository root:

```bash
uv run --locked --extra dev dbt compile
uv run --locked --extra dev ./scripts/run_unit_tests.sh
```

The test runner creates the fixture relations before executing the unit tests in
`tests/unit/` and forwards additional dbt options to both commands. For example,
to use an existing profile:

```bash
uv run --locked --extra dev ./scripts/run_unit_tests.sh --profile your_existing_profile
```

The fixtures exercise session boundaries, scoped and unscoped streams, zero
inactivity thresholds, deterministic event ordering, and output prefixes.

To compile an example analysis:

```bash
uv run --locked --extra dev dbt compile --select sessionize_events_example
```

The generated SQL is written to
`target/compiled/dbt_event_patterns/analyses/sessionize_events_example.sql`.

To execute the analysis and preview its results:

```bash
uv run --locked --extra dev dbt show --select sessionize_events_example --limit 10
```

To generate the documentation site:

```bash
uv run --locked --extra dev dbt docs generate
```

The generated site is written to `target/`.

## dbt v1 and v2

The same package macros support both runtimes. CI checks them separately:

| Extra | Runtime | Purpose |
| ----- | ------- | ------- |
| `dev` | dbt v2 (`dbt`) | Default development and documentation generation. |
| `dev-v2` | dbt v2 (`dbt`) | Explicit v2 selection in the CI matrix. |
| `dev-v1` | dbt v1 (`dbt-core` and `dbt-bigquery`) | v1 compatibility checks. |

Select one extra at a time because both runtimes provide the `dbt` command.
To run the unit tests with v1:

```bash
uv run --locked --extra dev-v1 ./scripts/run_unit_tests.sh
```

The package declares `require-dbt-version: ['>=1.6.0', '<3.0.0']`. Package users
use their own dbt installation and connection profile; the development extras
are only for working on this repository. Dependencies are recorded in `uv.lock`,
and CI installs them with `uv sync --locked`.

The lockfile pins the exact versions used for development and CI. Update the v2
runtime with `uv lock --upgrade-package dbt`, or the v1 runtime with
`uv lock --upgrade-package dbt-core --upgrade-package dbt-bigquery`, and commit
the updated lockfile.

To run the dbt v2 compatibility checks without warehouse credentials:

```bash
uv run --locked --extra dev-v2 python scripts/check_dbt_v2.py
```

The compatibility script uses placeholder BigQuery and Snowflake profiles from
`.github/dbt/compatibility/profiles.yml`. It parses with both adapters, checks
that model dependencies are preserved, renders all BigQuery models and analyses,
and verifies that executing public macros on Snowflake raises a clear error.
This allows Package Hub to parse the package with a placeholder adapter while
SQL execution remains specific to BigQuery.

The offline rendering check disables SQL static analysis because warehouse
metadata is unavailable. CI runs these checks in the `parse-checks` job alongside
the BigQuery warehouse tests for both runtimes.

## CI credentials and releases

The BigQuery checks and documentation jobs read the organization Actions secret
`DBT_BIGQUERY_CI_SERVICE_ACCOUNT_JSON_BASE64`. Grant this repository access and
set its value to the service-account JSON encoded with:

```bash
base64 -w 0 service-account.json
```

The service account needs permission to run BigQuery jobs and create fixture
views, plus **BigQuery Read Session User** (`roles/bigquery.readSessionUser`) on
the project for dbt v2. CI decodes the key on the runner and generates a profile
selected through `DBT_PROFILES_DIR`.

On pushes to `main`, CI generates and publishes documentation to GitHub Pages.
After the documentation and dbt v2 checks pass, the release job creates a tag
from the version in `dbt_project.yml` if it is newer than the latest tag. Keep
the versions in `dbt_project.yml`, `pyproject.toml`, and `uv.lock` aligned when
preparing a release.

## Test CI locally with act

With Docker running, install [act as a GitHub CLI extension](https://github.com/nektos/gh-act):

```bash
gh extension install nektos/gh-act
```

Run from the repository root:

```bash
SERVICE_ACCOUNT_JSON='/path/to/service-account.json'
gh act --actor nektos/act \
  --secret DBT_BIGQUERY_CI_SERVICE_ACCOUNT_JSON_BASE64="$(base64 -w0 "$SERVICE_ACCOUNT_JSON")" \
  -W .github/workflows/github-actions.yml \
  -P ubuntu-latest=catthehacker/ubuntu:act-latest
```

Replace the JSON path with your service-account keyfile. Keep the path quoted if
it contains spaces, including Windows paths mounted under `/mnt/c/` in WSL.
Use `DBT_BIGQUERY_CI_SERVICE_ACCOUNT_JSON_BASE64` as the secret name, matching the
workflow. The command runs the dbt v1/v2 warehouse tests and dbt v2 parsing checks.
The `nektos/act` actor skips documentation publishing and release tagging locally.

Add `--job checks` to run only the warehouse test matrix, or run just the parsing
checks without warehouse credentials:

```bash
gh act --actor nektos/act --job parse-checks \
  -W .github/workflows/github-actions.yml \
  -P ubuntu-latest=catthehacker/ubuntu:act-latest
```

If you use a standalone act installation, replace `gh act` with `act`.
