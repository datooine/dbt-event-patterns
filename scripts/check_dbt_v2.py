#!/usr/bin/env python3
"""Check dbt v2 parsing, BigQuery SQL rendering, and unsupported adapters offline."""

import json
import os
from pathlib import Path
import shlex
import subprocess
from tempfile import TemporaryDirectory


REPO_ROOT = Path(__file__).resolve().parent.parent
DBT_CMD = shlex.split(os.environ.get("DBT_CMD", "dbt"))


def main():
    env = {
        **os.environ,
        "DBT_SEND_ANONYMOUS_USAGE_STATS": "false",
        "DBT_DISABLE_VERSION_CHECK": "true",
        "DBT_PARTIAL_PARSE": "false",
        "DBT_WARN_ERROR": "true",
    }
    with TemporaryDirectory(prefix="dbt-event-patterns-v2-") as directory:
        artifact_root = Path(directory)

        def run(target, *args, expected_error=None):
            command = [
                *DBT_CMD,
                *args,
                "--project-dir", str(REPO_ROOT),
                "--profiles-dir", str(REPO_ROOT / ".github/dbt/compatibility"),
                "--target", target,
                "--target-path", str(artifact_root / target),
                "--log-path", str(artifact_root / target / "logs"),
            ]
            print(f"Running: {shlex.join(command)}", flush=True)
            result = subprocess.run(
                command, cwd=REPO_ROOT, env=env, text=True,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            )
            print(result.stdout, end="", flush=True)
            if expected_error:
                if result.returncode == 0 or expected_error not in result.stdout:
                    raise RuntimeError(f"Expected compiler error: {expected_error}")
            elif result.returncode:
                raise subprocess.CalledProcessError(result.returncode, command)

        model = "model.dbt_event_patterns.macro_sessionize_events_unscoped"
        for target in ("bigquery", "snowflake"):
            run(target, "parse")
            manifest = json.loads((artifact_root / target / "manifest.json").read_text())
            dependencies = manifest["nodes"][model]["depends_on"]["nodes"]
            if "model.dbt_event_patterns.macro_sessionize_events_data" not in dependencies:
                raise RuntimeError("Parsing lost the input model dependency")

        # Render the BigQuery implementation without querying warehouse metadata.
        run("bigquery", "compile", "--static-analysis", "off")
        manifest = json.loads((artifact_root / "bigquery/manifest.json").read_text())
        sql = manifest["nodes"][model]["compiled_code"]
        if "TIMESTAMP_ADD" not in sql or "SHA256" not in sql:
            raise RuntimeError("The BigQuery sessionization SQL was not rendered")

        # Parsing succeeds, but using the macro on an unsupported adapter still fails.
        args = {
            "relation": "sample_events",
            "event_ts": "event_at",
            "partition_by": ["user_id"],
            "inactivity_seconds": 300,
            "tie_breaker": ["event_id"],
        }
        run(
            "snowflake", "run-operation", "sessionize_events", "--args", json.dumps(args),
            expected_error="dbt_event_patterns: sessionize_events not implemented for adapter 'snowflake'. Supported: bigquery.",
        )

    print("dbt v2 compatibility checks passed.")


if __name__ == "__main__":
    main()
