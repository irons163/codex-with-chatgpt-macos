# Secure Updates and Releases

`CodexWithChatGPT.app` uses Sparkle 2.9.1 for in-app updates. Distribution
artifacts are Developer ID signed, notarized by Apple, and signed again with a
Sparkle Ed25519 key. The release workflow rejects unsigned update enclosures.

## Important: repository visibility

The GitHub repository is currently private. GitHub Release assets in a private
repository require authentication, while this Sparkle client deliberately does
not store a GitHub token. The workflow can build and publish releases now, but
installed apps cannot download appcasts or DMGs until the repository is public
or the feeds and installers are hosted at another authenticated update service.

Do not embed a personal access token in the app or appcast URL.

## Files

- `.github/workflows/ci.yml` builds, tests, and packages native arm64 and x86_64
  app bundles without release credentials.
- `.github/workflows/release.yml` validates an immutable published tag, signs
  and notarizes both DMGs, then uploads installers, dSYMs, checksums, and feeds.
- `scripts/package-app.sh` creates the app bundle and embeds `c2c` plus
  `Sparkle.framework`.
- `scripts/build-release-dmg.sh` creates the signed/notarized DMG and verifies
  the Sparkle private key against the packaged public key.
- `scripts/generate-sparkle-appcast.sh` creates signed architecture-specific
  Stable or Beta feeds.

## Update feeds

| Channel | Apple Silicon | Intel |
| --- | --- | --- |
| Stable | `appcast-arm64.xml` | `appcast-x86_64.xml` |
| Beta | `appcast-beta-arm64.xml` | `appcast-beta-x86_64.xml` |

Stable feeds live on the latest Stable GitHub Release. Beta feeds are also
uploaded to that Stable release because GitHub's `releases/latest` URL ignores
prereleases. Therefore the first release must be Stable.

## Sparkle key

Use Sparkle 2.9.1's own tools to generate one long-lived key pair:

```bash
./bin/generate_keys --account codex-with-chatgpt-macos
./bin/generate_keys --account codex-with-chatgpt-macos -p
./bin/generate_keys --account codex-with-chatgpt-macos -x sparkle-private-key
```

Store the exported private key as `SPARKLE_ED_PRIVATE_KEY`. Store the public
key printed by `-p` as `SPARKLE_PUBLIC_ED_KEY`. Never commit either private key
or Apple release credential. Keep an encrypted offline backup and use Sparkle's
documented key-rotation process if the key must change.

## Required GitHub secrets

Configure this repository secret so the read-only validation job can check it:

- `SPARKLE_PUBLIC_ED_KEY`

Create a `release-production` Environment and configure these secrets there:

- `APPLE_CERTIFICATE_P12_BASE64`
- `APPLE_CERTIFICATE_PASSWORD`
- `KEYCHAIN_PASSWORD`
- `APPLE_TEAM_ID`
- `APPLE_API_KEY_ID`
- `APPLE_API_ISSUER_ID`
- `APPLE_API_PRIVATE_KEY_BASE64`
- `SPARKLE_ED_PRIVATE_KEY`

The certificate must contain a Developer ID Application certificate and its
private key. The API key is an App Store Connect key accepted by `notarytool`.
Require approval for the `release-production` Environment and restrict it to
protected `v*` tags.

## Versioning

Before every release, update `Packaging/Info.plist`:

- `CFBundleShortVersionString` must match the tag after removing `v`.
- `CFBundleVersion` must be an unsigned integer greater than every prior Stable
  and Beta build number.
- Stable tags must look like `v0.1.1`; prerelease tags such as
  `v0.1.2-beta.1` must be marked as GitHub prereleases.

Sparkle orders updates by `CFBundleVersion`, not only by the display version.
The workflow reads previously published appcasts and rejects reused or
decreasing build numbers.

## Publish

1. Update both version values in `Packaging/Info.plist`.
2. Commit and push the release preparation.
3. Create and push the matching immutable `v*` tag.
4. Create and publish a GitHub Release from that tag. Mark Beta builds as
   prereleases.
5. Wait for the `Release` workflow and any Environment approval.

The workflow can be rerun manually for an existing published release by
providing its tag and channel. It never creates or moves tags.

## Local verification

```bash
bash -n scripts/*.sh
scripts/test-generate-sparkle-appcast.sh
scripts/test-validate-release-build-order.sh
swift test
CONFIGURATION=release ARCHS="$(uname -m)" scripts/package-app.sh
codesign --verify --deep --strict dist/CodexWithChatGPT.app
```

Local app packaging uses an ad-hoc signature and enables Sparkle's insecure
update allowance only in that local bundle because no production public key is
available. Developer ID builds require `SPARKLE_PUBLIC_ED_KEY`, remove the
allowance, and fail if it remains present.
