# Recording tests

The Swift Testing target compiles the production app logic, excluding its app entry point. It uses generated media and does not request screen, microphone, camera, or input-monitoring access.

Run all tests from the repository root with Swift 6 or later and a macOS 15+ SDK:

```sh
python3 scripts/test-recording.py
```

The runner follows the app build's SDK preference, keeps build caches under `build/`, and works with Xcode or Command Line Tools. For CLT installations with mismatched SwiftPM private interfaces, it uses a local copy of the installed public interfaces without changing the toolchain. Media tests need access to the macOS graphics renderer and media encoders.

Run or list specific tests using SwiftPM options:

```sh
python3 scripts/test-recording.py --filter RecordingGeometryTests
python3 scripts/test-recording.py --filter MP4ExportTests
python3 scripts/test-recording.py list
```

With a compatible active SDK/toolchain, the target also runs with `swift test --disable-xctest`.

The release workflow uploads a `recording-test-failure` artifact when tests fail. It includes the test log and, for preview/export parity failures, the compared PNGs, synthetic source clips, exported MP4, requested and actual frame times, and measured RGB difference. The pixel tolerance remains the same on CI and locally. Run **Actions → Release → Run workflow** on a branch containing diagnostic changes to investigate without publishing a release. Rerunning an existing tag job uses the original tagged code.

To save frame diagnostics locally, set `WALK_AND_ROLL_TEST_ARTIFACTS` to an output directory when running the tests.

The release workflow also checks signing with a disposable keychain and a small app fixture:

```sh
python3 Tests/test_local_signing.py
```

This checks that a fresh identity remains searchable during signing, is reused on a second build, and restores the original keychain search list after both success and failure. It leaves `.local-signing/` untouched and deletes only its temporary test keychain.

| Suite | Coverage |
| --- | --- |
| `RecordingEditsTests` | Easing, overlap resolution, equal-start precedence, invalid instructions |
| `RecordingGeometryTests` | Aspect fit, edge clamping, crop placement, inverse preview hit testing |
| `RecordingResolutionTests` | Native capture detail, output dimensions, even dimensions, 4K limit |
| `RecordingImageSamplingTests` | Enlarged edge contrast, halo prevention, opaque boundaries, rotation |
| `RecordingCompositionTests` | Source/preview/export color consistency, preview/export parity, source shapes, frame styles, non-destructive editing |
| `RecordingOverlayTests` | Fixed camera/badges, click alignment, camera timing and corners |
| `MP4ExportTests` | H.264/AAC output, audio mixing, cancellation/retry, destination/original protection |
| `RecordingPreviewTests` | AVPlayer frames, seeking, edit rebuilds, playback/replay, camera fallback |

Media tests create a unique temporary directory per test and remove it afterward. Export cancellation is triggered by observed progress; player waits are bounded and driven by player state. These checks do not replace live permission, device synchronization, physical input, or moved-window capture checks.
