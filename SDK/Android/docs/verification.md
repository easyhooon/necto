# Verification

What was checked, and how to check it again. Update it when behaviour changes.

## Automated tests

`./gradlew build` runs them all.

| Module | What they cover |
| --- | --- |
| necto-core | Protocol models and JSON, schema validation, the SDK runtime, panels carried as Java resources. The runtime tests feed it a hostile peer: frames outside 1 byte to 64 KiB, nesting past 64, invalid UTF-8, trailing JSON, a stalled frame, a silent handshake, an oversized handshake answer, long or duplicate request IDs and more than 32 active requests. Each closes the session, and the next connection works |

## Against a running app

`script/android-sample <serial>` builds the sample and Necto, installs the sample and
connects the two. The scripts below then run against it. The repository's
[docs/verification.md](../../../docs/verification.md) describes each one.

| Script | What it checks |
| --- | --- |
| `script/test-android-sample` | The target appears as `android:<serial>`. The `plugin-sample` panel the app carries answers. Unexpected input is refused with `INVALID_INPUT`. A stream ends and a new one starts. A force stop removes the target, and a relaunch brings it back |
| `script/test-android-security` | A silent handshake is dropped after 5 seconds. Frames of 0 bytes, 64 KiB + 1 and 4 GiB are dropped, as are nesting past 64, a frame that stalls for 10 seconds, and 33 concurrent requests. A request then succeeds without restarting the app |
| `script/test-android-artifacts` | `necto-android` declares no permission. `necto-core` carries no panels. Only the debug sample is debuggable |

The connection and security checks passed on an Android 17 emulator
(`sdk_gphone64_arm64`, API 37) and over USB on a Samsung Galaxy S25+ (`SM-S936N`,
Android 17, API 37) while the shipped plugins were still part of this change. The
scripts have since moved to `plugin-sample` and have not been run again.

## Known limitations

- One session is served at a time.
