#!/usr/bin/env python3
"""Report whether build inputs match a commit, allowing local signing settings."""

import json
import subprocess
import sys
from pathlib import Path


PROJECT_PATH = "Tugboat.xcodeproj/project.pbxproj"


def run(arguments, input_data=None):
    return subprocess.run(arguments, input=input_data, text=True, check=True, capture_output=True).stdout


def normalized_project(data):
    project = json.loads(run(["/usr/bin/plutil", "-convert", "json", "-o", "-", "-"], data))
    for item in project["objects"].values():
        settings = item.get("buildSettings", {})
        for key in list(settings):
            if key in {"CODE_SIGN_IDENTITY", "CODE_SIGN_STYLE", "DEVELOPMENT_TEAM"} or key.startswith("CODE_SIGN_IDENTITY["):
                settings.pop(key)
        for attributes in item.get("attributes", {}).get("TargetAttributes", {}).values():
            attributes.pop("DevelopmentTeam", None)
            attributes.pop("ProvisioningStyle", None)
    return project


def source_matches_commit(repository, commit):
    git = ["/usr/bin/git", "-C", str(repository)]
    changed = set(run(git + ["diff", "--name-only", commit, "--"]).splitlines())
    if changed - {PROJECT_PATH}:
        return False
    if PROJECT_PATH in changed:
        committed = run(git + ["show", commit + ":" + PROJECT_PATH])
        current = (repository / PROJECT_PATH).read_text()
        if normalized_project(committed) != normalized_project(current):
            return False
    untracked = run(git + ["ls-files", "--others", "--exclude-standard", "-z"]).split("\0")
    return not any(path.startswith(("Tugboat/", "Tugboat.xcodeproj/", "scripts/")) for path in untracked if path)


def main():
    if len(sys.argv) != 3:
        raise SystemExit("Usage: build-source-state.py repository-root commit")
    try:
        matches = source_matches_commit(Path(sys.argv[1]), sys.argv[2])
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print("Could not verify build inputs against the source commit: " + str(error), file=sys.stderr)
        matches = False
    print("true" if matches else "false")


if __name__ == "__main__":
    main()
