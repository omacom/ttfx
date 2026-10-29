"""Select expensive FX checks without skipping the workflow's required status."""

import json
import os
from pathlib import Path
import subprocess


def documentation_only(path):
    # Allow only known documentation locations; new code/build paths run by default.
    return (path.startswith("docs/") or path in {"LICENSE", "NOTICE"}
            or ("/" not in path and path.endswith(".md")))


def required(event_name, event):
    if event_name == "workflow_dispatch":
        return True, "Manual run requests the full suite."
    if event_name == "pull_request":
        pr = event["pull_request"]
        if pr["draft"]:
            return False, "Draft PR: quick checks only."
        # Check the whole PR, not just its latest commit. A documentation follow-up
        # must not hide earlier Rust changes after cancelling the previous run.
        revision = f'{pr["base"]["sha"]}...{pr["head"]["sha"]}'
    elif event_name == "push":
        if event["before"] == "0" * 40:
            return True, "New branch: run the full suite."
        revision = f'{event["before"]}..{event["after"]}'
    else:
        raise ValueError(f"Unsupported CI event: {event_name}")

    # Disabling renames includes both the removed and added path. Moving code
    # into docs must still trigger checks. NUL separators handle unusual names.
    result = subprocess.run(
        ["git", "diff", "--no-ext-diff", "--no-renames", "--name-only", "-z",
         revision, "--"], check=True, capture_output=True,
    )
    paths = [os.fsdecode(path) for path in result.stdout.split(b"\0") if path]
    if all(documentation_only(path) for path in paths):
        return False, "No changes outside documentation."
    return True, "Changes outside documentation require the full suite."


if __name__ == "__main__":
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    run_full, reason = required(os.environ["GITHUB_EVENT_NAME"], event)
    print(reason)
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"run-full={str(run_full).lower()}\n")
