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

| Suite | Coverage |
| --- | --- |
| `RecordingEditsTests` | Easing, overlap resolution, equal-start precedence, invalid instructions |
| `RecordingGeometryTests` | Aspect fit, edge clamping, crop placement, inverse preview hit testing |
| `RecordingResolutionTests` | Native capture detail, output dimensions, even dimensions, 4K limit |
| `RecordingImageSamplingTests` | Enlarged edge contrast, halo prevention, opaque boundaries, rotation |
| `RecordingCompositionTests` | Preview/export parity, source shapes, frame styles, non-destructive editing |
| `RecordingOverlayTests` | Fixed camera/badges, click alignment, camera timing and corners |
| `MP4ExportTests` | H.264/AAC output, audio mixing, cancellation/retry, destination/original protection |
| `RecordingPreviewTests` | AVPlayer frames, seeking, edit rebuilds, playback/replay, camera fallback |

Media tests create a unique temporary directory per test and remove it afterward. Export cancellation is triggered by observed progress; player waits are bounded and driven by player state. These checks do not replace live permission, device synchronization, physical input, or moved-window capture checks.
