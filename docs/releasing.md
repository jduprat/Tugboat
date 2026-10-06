# Releasing Tugboat from Xcode

Use this process on your personal release Mac. **Product → Archive** is the manual release trigger: Xcode creates a Release archive, then the scheme's post-action exports, signs, notarizes, and publishes it. The version tag is created after the DMG is ready; pushing a tag does not start a GitHub build.

Apple signing and notarization credentials stay on the release Mac. GitHub retains only the existing Sparkle update-signing credential and uses it in a manually invoked job after the finished DMG is published.

## One-time setup on the release Mac

### 1. Install the tools and signing identity

Use Xcode 27 and install the GitHub CLI (`gh`). The GitHub CLI must be authenticated with your personal account and have permission to push repository contents and dispatch Actions workflows for `jduprat/Tugboat`. A fine-grained token needs **Contents: write** and **Actions: write**; a classic token uses the `repo` scope.

The login Keychain must contain your **Developer ID Application** certificate and its matching private key. List valid code-signing identities with:

```bash
security find-identity -v -p codesigning
```

Record the 40-character SHA-1 fingerprint for the identity you want to use. The release helper selects that exact identity; it does not export the private key.

### 2. Store notarization credentials in Keychain

Create an App Store Connect **team API key** using Apple's [API-key instructions](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api). The controls are under **Users and Access → Integrations → App Store Connect API → Team Keys**. Keep the downloaded `.p8` file outside the repository, and record its key ID and issuer ID.

Store and validate a local notarization profile:

```bash
xcrun notarytool store-credentials TugboatNotary \
  --key "/path/to/AuthKey_KEYID.p8" \
  --key-id "KEYID" \
  --issuer "ISSUER_ID"
```

Replace the placeholders with your local file path and the IDs from App Store Connect. This stores the profile in Keychain and validates it with Apple. It does not send the private key to GitHub or require an Apple account to be added to Xcode.

### 3. Create the local release configuration

Create `~/Library/Application Support/Tugboat/Release/config.json` on the release Mac:

```json
{
  "signing_identity": "YOUR_40_CHARACTER_CERTIFICATE_FINGERPRINT",
  "notary_profile": "TugboatNotary"
}
```

This file contains references to local credentials, not the credentials themselves. Keep it outside Git. Do not put certificate archives, private keys, or passwords in the repository or the Xcode scheme.

The shared scheme contains only a call to `scripts/release-from-archive.py` with Xcode's `ARCHIVE_PATH`. A Mac without the local configuration receives a setup error instead of publishing a release.

## Make a release

1. Update the existing checkout to include the latest release helper and workflow.
2. Set the intended version in Xcode's Tugboat target. The helper reads the version from the archive and creates the corresponding tag, such as `v0.2.1`.
3. Commit the intended source changes and run your local tests. Archive does not run tests automatically. Build metadata records whether the source matches the commit, allowing local signing-only changes to the project file. Other uncommitted source changes or untracked build inputs prevent publication because they would not be represented by the version tag.
4. Select the **Tugboat** scheme and choose **Product → Archive**.
5. Follow the release notifications. The helper opens the GitHub release page after the DMG and update feed are both published.

The Archive post-action performs these steps:

- Export the exact archive Xcode just created using the configured Developer ID identity.
- Verify the exported app's signature, version, build number, source commit, and Apple silicon/Intel architectures.
- Create and sign the DMG, submit it to Apple, require an accepted notarization result, attach the ticket, and validate the finished DMG.
- Create an annotated version tag pointing to the archive's source commit and push it.
- Publish the DMG as a GitHub Release.
- Invoke the **Publish Sparkle feed** job, which verifies the notarized DMG, signs its update metadata using the existing Sparkle credential, and updates `appcast.xml`.

GitHub performs no app build or tests in this process. Ordinary pushes and tag pushes do not run workflows.

## Results and recovery

The Xcode archive and its debug symbols remain available in Organizer. Exported files, the notarized DMG, notarization responses, and a release log are retained under `~/Library/Application Support/Tugboat/Releases/`.

Xcode does not reliably show post-action script errors in the build log. The helper sends progress notifications and opens its release log on failure. An archive appearing in Organizer confirms only that archiving completed, not that publication completed.

If export or notarization fails, the helper stops before creating a tag or GitHub Release. After correcting the problem, you can choose **Product → Archive** again or rerun the helper against an archive created with this release setup:

```bash
/usr/bin/python3 scripts/release-from-archive.py "/path/to/Tugboat.xcarchive"
```

An existing version tag is accepted only when it points to the same source commit. The helper does not move tags or replace existing GitHub releases automatically.

Archives made before this release setup are rejected because their source commits may still contain the old tag-triggered GitHub release workflow.

If the DMG is published but the update-feed job fails, the manual download remains available. Resolve the reported GitHub Actions error, then rerun **Publish Sparkle feed** from GitHub Actions with the published version tag. This retries only update-feed publication.

## Credential boundaries

The Developer ID private key and notarization credential remain on the release Mac. GitHub receives the signed, notarized DMG and public release metadata. The signed app exposes its public certificate identity, as expected, but does not contain its private key.

Sparkle signing remains separate: the feed-only GitHub job uses the Sparkle credential already stored there. No Apple signing or notarization credential is needed by GitHub.
