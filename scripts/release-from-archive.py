#!/usr/bin/env python3
"""Publish the archive supplied by Xcode using credentials stored on the release Mac."""

import datetime
import json
import os
import plistlib
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parent.parent
GITHUB_REPOSITORY = "jduprat/Tugboat"
BUNDLE_IDENTIFIER = "io.github.jduprat.Tugboat"
CONFIG_PATH = Path.home() / "Library/Application Support/Tugboat/Release/config.json"
OUTPUT_ROOT = Path.home() / "Library/Application Support/Tugboat/Releases"


class ReleaseError(Exception):
    pass


class Publisher:
    def __init__(self, archive):
        self.archive = Path(archive).resolve()
        self.started = datetime.datetime.now(datetime.timezone.utc)
        self.output = OUTPUT_ROOT / self.started.strftime("%Y%m%d-%H%M%S-%f")
        self.output.mkdir(parents=True)
        self.log_path = self.output / "release.log"
        self.log = self.log_path.open("w", buffering=1)
        self.environment = os.environ.copy()
        self.environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + self.environment.get("PATH", "/usr/bin:/bin")

    def note(self, message):
        print(message, flush=True)
        print(message, file=self.log, flush=True)

    def notify(self, message):
        subprocess.run(
            ["osascript", "-e", 'on run argv\ndisplay notification (item 1 of argv) with title "Tugboat Release"\nend run', message],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )

    def run(self, arguments, capture=False, check=True, input_data=None):
        arguments = [str(argument) for argument in arguments]
        print("$ " + shlex.join(arguments), file=self.log, flush=True)
        result = subprocess.run(
            arguments, cwd=REPOSITORY, env=self.environment, text=True, input=input_data,
            stdout=subprocess.PIPE if capture else self.log,
            stderr=subprocess.PIPE if capture else subprocess.STDOUT,
        )
        if result.returncode and check:
            if capture and result.stderr:
                print(result.stderr, file=self.log, flush=True)
            raise ReleaseError(f"{arguments[0]} failed with exit code {result.returncode}")
        return result

    def git(self, *arguments):
        return self.run(["git", *arguments], capture=True).stdout.strip()

    def load_configuration(self):
        try:
            configuration = json.loads(CONFIG_PATH.read_text())
        except (OSError, json.JSONDecodeError) as error:
            raise ReleaseError(f"Configure this release Mac using docs/releasing.md. Could not read {CONFIG_PATH}: {error}")
        if not isinstance(configuration, dict):
            raise ReleaseError("Local release configuration must be a JSON object. See docs/releasing.md.")
        identity = configuration.get("signing_identity", "")
        profile = configuration.get("notary_profile", "")
        if not isinstance(identity, str) or not isinstance(profile, str):
            raise ReleaseError("Local release configuration needs signing_identity and notary_profile. See docs/releasing.md.")
        identity = identity.upper()
        if not re.fullmatch(r"[0-9A-F]{40}", identity) or not profile:
            raise ReleaseError("Local release configuration needs signing_identity and notary_profile. See docs/releasing.md.")
        identities = self.run(["security", "find-identity", "-v", "-p", "codesigning"], capture=True).stdout
        matches = re.findall(r'\b([0-9A-F]{40}) "Developer ID Application:.*\(([A-Z0-9]{10})\)"', identities)
        selected = [team for fingerprint, team in matches if fingerprint == identity]
        if len(selected) != 1:
            raise ReleaseError("The configured Developer ID Application identity is not available in Keychain.")
        self.identity = identity
        self.team_id = selected[0]
        self.notary_profile = profile
        self.run(["xcrun", "notarytool", "history", "--keychain-profile", profile, "--output-format", "json"], capture=True)
        push_url = self.git("remote", "get-url", "--push", "origin")
        prefixes = ("https://github.com/", "git@github.com:", "ssh://git@github.com/")
        remote_repository = next((push_url[len(prefix):] for prefix in prefixes if push_url.startswith(prefix)), "")
        if remote_repository.removesuffix(".git").lower() != GITHUB_REPOSITORY.lower():
            raise ReleaseError("The origin push URL must target the same Tugboat repository used for GitHub publication.")
        self.push_url = push_url
        permission = self.run(["gh", "api", f"repos/{GITHUB_REPOSITORY}", "--jq", ".permissions.push"], capture=True).stdout.strip()
        if permission != "true":
            raise ReleaseError("GitHub CLI needs push access to the Tugboat repository on this release Mac.")
        workflow_state = self.run(["gh", "api", f"repos/{GITHUB_REPOSITORY}/actions/workflows/publish-appcast.yml", "--jq", ".state"], capture=True).stdout.strip()
        if workflow_state != "active":
            raise ReleaseError("The Publish Sparkle feed workflow must be active on GitHub before releasing.")

    @staticmethod
    def read_plist(path):
        with Path(path).open("rb") as source:
            return plistlib.load(source)

    def load_archive(self):
        try:
            archive_info = self.read_plist(self.archive / "Info.plist")
            application_path = archive_info["ApplicationProperties"]["ApplicationPath"]
            products = (self.archive / "Products").resolve()
            self.archived_app = (products / application_path).resolve()
            if os.path.commonpath([products, self.archived_app]) != str(products):
                raise ReleaseError("The archive has an invalid application path.")
            self.archive_app_info = self.read_plist(self.archived_app / "Contents/Info.plist")
        except (OSError, KeyError, plistlib.InvalidFileException) as error:
            raise ReleaseError(f"Xcode did not supply a usable application archive: {error}")
        self.run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", self.archived_app])
        info = self.archive_app_info
        self.version = str(info.get("CFBundleShortVersionString", ""))
        self.build = str(info.get("CFBundleVersion", ""))
        self.commit = str(info.get("TugboatGitCommit", ""))
        if info.get("CFBundleIdentifier") != BUNDLE_IDENTIFIER:
            raise ReleaseError("The archive is not a Tugboat application archive.")
        if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", self.version) or not self.build.isdigit():
            raise ReleaseError("The archive has an invalid release version or build number.")
        if not re.fullmatch(r"[0-9a-fA-F]{40}|[0-9a-fA-F]{64}", self.commit):
            raise ReleaseError("The archive does not identify its source commit.")
        self.run(["git", "cat-file", "-e", self.commit + "^{commit}"])
        self.tag = "v" + self.version
        self.note(f"Archive: {self.archive}\nVersion: {self.version} ({self.build})\nCommit: {self.commit}")
        if info.get("TugboatGitSourceMatchesCommit") is not True:
            raise ReleaseError("The archive does not verify that its build inputs match the source commit. Commit the intended source and create a new archive.")
        old_workflow = self.run(["git", "cat-file", "-e", self.commit + ":.github/workflows/release.yml"], capture=True, check=False)
        new_workflow = self.run(["git", "cat-file", "-e", self.commit + ":.github/workflows/publish-appcast.yml"], capture=True, check=False)
        if old_workflow.returncode == 0 or new_workflow.returncode != 0:
            raise ReleaseError("The archive predates the local release workflow. Create a new archive from a commit containing this release setup.")

    def check_release_available(self):
        result = self.run(["gh", "api", f"repos/{GITHUB_REPOSITORY}/releases/tags/{self.tag}"], capture=True, check=False)
        if result.returncode == 0:
            raise ReleaseError(f"GitHub release {self.tag} already exists. Existing releases are not replaced automatically.")
        if "HTTP 404" not in result.stderr:
            raise ReleaseError("Could not check whether the GitHub release already exists.")

    def export(self):
        self.notify(f"Exporting Tugboat {self.version}…")
        options = self.output / "ExportOptions.plist"
        with options.open("wb") as destination:
            plistlib.dump({
                "destination": "export", "method": "developer-id", "signingStyle": "manual",
                "signingCertificate": self.identity, "teamID": self.team_id,
            }, destination)
        export_directory = self.output / "export"
        self.run(["xcodebuild", "-exportArchive", "-archivePath", self.archive,
                  "-exportOptionsPlist", options, "-exportPath", export_directory])
        self.app = export_directory / "Tugboat.app"
        self.run(["codesign", "--verify", "--deep", "--strict", "--verbose=2", self.app])
        exported = self.read_plist(self.app / "Contents/Info.plist")
        for key in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion", "TugboatGitCommit"):
            if exported.get(key) != self.archive_app_info.get(key):
                raise ReleaseError(f"Export changed the archive's {key} value.")
        signature = self.run(["codesign", "--display", "--verbose=4", self.app], capture=True).stderr
        if f"TeamIdentifier={self.team_id}" not in signature or "Authority=Developer ID Application:" not in signature:
            raise ReleaseError("The exported app does not use the configured Developer ID team.")
        executable = self.app / "Contents/MacOS" / exported["CFBundleExecutable"]
        architectures = set(self.run(["lipo", "-archs", executable], capture=True).stdout.split())
        if not {"arm64", "x86_64"}.issubset(architectures):
            raise ReleaseError("The release archive must include both Apple silicon and Intel binaries.")

    def package_and_notarize(self):
        self.notify(f"Packaging and notarizing Tugboat {self.version}…")
        root = self.output / "dmg-root"
        root.mkdir()
        self.run(["ditto", self.app, root / "Tugboat.app"])
        (root / "Applications").symlink_to("/Applications")
        self.dmg = self.output / f"Tugboat-{self.version}.dmg"
        self.run(["hdiutil", "create", "-srcfolder", root, "-volname", f"Tugboat {self.version}",
                  "-fs", "HFS+", "-format", "UDZO", self.dmg])
        self.run(["codesign", "--force", "--timestamp", "--sign", self.identity, self.dmg])
        self.run(["hdiutil", "verify", self.dmg])
        submission = self.run(["xcrun", "notarytool", "submit", self.dmg, "--keychain-profile", self.notary_profile,
                               "--wait", "--output-format", "json"], capture=True, check=False)
        (self.output / "notary-submission.json").write_text(submission.stdout)
        if submission.stderr:
            print(submission.stderr, file=self.log, flush=True)
        try:
            result = json.loads(submission.stdout)
        except json.JSONDecodeError:
            result = {}
        submission_id = result.get("id")
        log_result = None
        if submission_id:
            log_result = self.run(["xcrun", "notarytool", "log", submission_id, "--keychain-profile", self.notary_profile,
                                   self.output / "notary-log.json"], check=False)
        if submission.returncode or result.get("status") != "Accepted" or not submission_id:
            raise ReleaseError(f"Apple did not accept the notarization submission (status: {result.get('status', 'unavailable')}).")
        if log_result is None or log_result.returncode:
            raise ReleaseError("Apple accepted the submission, but the notarization log could not be retrieved.")
        self.run(["xcrun", "stapler", "staple", self.dmg])
        self.run(["xcrun", "stapler", "validate", self.dmg])
        self.run(["codesign", "--verify", "--verbose=2", self.dmg])
        self.run(["spctl", "--assess", "--type", "open", "--context", "context:primary-signature", "--verbose=4", self.dmg])

    def publish(self):
        self.notify(f"Publishing Tugboat {self.version}…")
        local = self.run(["git", "rev-parse", "--verify", f"refs/tags/{self.tag}^{{commit}}"], capture=True, check=False)
        if local.returncode == 0 and local.stdout.strip() != self.commit:
            raise ReleaseError(f"Local tag {self.tag} points to another commit.")
        remote = self.git("ls-remote", "--tags", self.push_url, f"refs/tags/{self.tag}", f"refs/tags/{self.tag}^{{}}")
        remote_lines = [line.split() for line in remote.splitlines()]
        if remote_lines:
            remote_commit = next((sha for sha, ref in remote_lines if ref.endswith("^{}")), remote_lines[0][0])
            if remote_commit != self.commit:
                raise ReleaseError(f"Remote tag {self.tag} points to another commit.")
        else:
            if local.returncode:
                self.run(["git", "-c", "tag.gpgSign=false", "tag", "-a", self.tag, self.commit, "-m", f"Tugboat {self.version}"])
            self.run(["git", "push", self.push_url, f"refs/tags/{self.tag}"])
        self.run(["gh", "release", "create", self.tag, self.dmg, "--repo", GITHUB_REPOSITORY,
                  "--verify-tag", "--title", f"Tugboat {self.version}", "--generate-notes"])
        self.release_url = f"https://github.com/{GITHUB_REPOSITORY}/releases/tag/{self.tag}"
        self.note(f"Published {self.release_url}")
        self.publish_update_feed()

    def publish_update_feed(self):
        self.notify(f"Updating the Tugboat {self.version} update feed…")
        dispatched_at = datetime.datetime.now(datetime.timezone.utc)
        dispatched = self.run(["gh", "workflow", "run", "publish-appcast.yml", "--repo", GITHUB_REPOSITORY,
                               "--ref", "main", "-f", f"tag={self.tag}"], capture=True)
        match = re.search(r"/actions/runs/([0-9]+)", dispatched.stdout)
        run_id = match.group(1) if match else None
        if not run_id:
            title = f"Publish Sparkle feed for {self.tag}"
            for _ in range(15):
                runs = json.loads(self.run(["gh", "run", "list", "--repo", GITHUB_REPOSITORY, "--workflow", "publish-appcast.yml",
                                            "--event", "workflow_dispatch", "--branch", "main", "--limit", "10",
                                            "--json", "databaseId,displayTitle,createdAt"], capture=True).stdout)
                candidates = [run for run in runs if run["displayTitle"] == title and
                              datetime.datetime.fromisoformat(run["createdAt"].replace("Z", "+00:00")) >= dispatched_at - datetime.timedelta(seconds=5)]
                if candidates:
                    run_id = str(candidates[0]["databaseId"])
                    break
                time.sleep(2)
        if not run_id:
            raise ReleaseError("The release is published, but the update-feed workflow run could not be located. Check GitHub Actions.")
        self.note(f"Update-feed workflow: https://github.com/{GITHUB_REPOSITORY}/actions/runs/{run_id}")
        result = self.run(["gh", "run", "watch", run_id, "--repo", GITHUB_REPOSITORY, "--exit-status"], check=False)
        if result.returncode:
            raise ReleaseError("The release is published, but the update-feed workflow failed. Rerun that workflow after resolving its reported error.")

    def execute(self):
        self.load_archive()
        self.load_configuration()
        self.check_release_available()
        self.export()
        self.package_and_notarize()
        self.publish()
        self.note(f"Published {self.release_url}\nRelease files: {self.output}")
        self.notify(f"Tugboat {self.version} is published and its update feed is ready.")
        subprocess.run(["open", self.release_url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main():
    if len(sys.argv) != 2 or not sys.argv[1]:
        subprocess.run(["osascript", "-e", 'display alert "Tugboat Release" message "Xcode did not provide an archive path. Check the Archive post-action setup." as critical'])
        raise SystemExit("Usage: release-from-archive.py /absolute/path/to/Tugboat.xcarchive")
    publisher = Publisher(sys.argv[1])
    try:
        publisher.execute()
    except (ReleaseError, OSError, ValueError, KeyError, plistlib.InvalidFileException) as error:
        publisher.note("Release failed: " + str(error))
        publisher.notify("Tugboat release failed. Opening the release log.")
        subprocess.run(["open", publisher.log_path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        raise SystemExit(1)
    finally:
        publisher.log.close()


if __name__ == "__main__":
    main()
