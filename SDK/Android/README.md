# Necto for Android

The app side of Necto for Android apps. An Android app speaks the same protocol (v1) as
an iOS app, so the Mac app shows it like any other target.

## Connecting

The SDK does not open a network port. In a debuggable build, `NectoAndroid.start` binds
a Unix socket in the abstract namespace under a random name, `necto.<64 hex>`, and
writes that name to the app's private `no_backup/necto-endpoint`. Only ADB reaches it:

- The name is readable through `adb shell run-as <app>` alone, which needs a debuggable
  app.
- Any app could still connect to a name it knew, so the SDK accepts a connection only
  from the shell and root users that adbd runs as.
- In an app that is not debuggable, `start` logs a warning and does nothing.

Necto on the Mac does the rest, alongside its iOS connections, when the Android SDK is
installed. It finds `adb` through `ANDROID_HOME`, `ANDROID_SDK_ROOT` or
`~/Library/Android/sdk`, and starts the local adb server if none is running. Then, every
two seconds:

- It lists authorized devices on a USB cable and real local emulators. Wireless ADB is
  refused.
- On each, it asks the running third-party apps for their name through `run-as`.
- It forwards a private Unix socket to each name it finds (`adb forward
  localfilesystem:<private path> localabstract:<name>`) and connects there. An app that
  restarts under a new name is forwarded again; an app or device that goes away loses
  its forward.

`script/android-sample <serial>` builds the sample and a separate Necto, installs the
sample on a USB device or a local emulator, and runs that Necto until Ctrl-C.

The device appears as `android:<serial>`, labelled `Android <version>`.

## Modules

| Module | Contents | iOS counterpart |
| --- | --- | --- |
| `necto-core` (plain JVM) | Protocol models, JSON and schema validation, framed message transport, coroutine SDK runtime, the `NectoPlugin` contract | `NectoModel`, `NectoTransport`, `NectoSDK` |
| `necto-android` | The ADB listener and app identity from `Context` | The UIKit parts of `NectoSDK` |

The plugins Necto ships come in a separate change.

The Maven group and package root is `im.toss.necto`.

## Usage

```kotlin
class App : Application() {
    override fun onCreate() {
        super.onCreate()
        if (BuildConfig.DEBUG) NectoAndroid.start(this, listOf(ThingsPlugin()))
    }
}
```

`necto-android` declares no permissions. Custom plugins take the same shape as on iOS:

```kotlin
class ThingsPlugin : NectoPlugin {
    override val id = "com.example.things"
    override fun register(necto: NectoRegistrar) {
        necto.handle("things.list") { jsonObject("things" to jsonArray(...)) }
        necto.stream("things.observe") { _, out -> changes.collect { out.send(it) } }
    }
}
```

## The connection is not trusted

Whatever reaches the socket is treated as hostile, and a session that misbehaves is
closed. The listener keeps waiting, so the next connection works without restarting the
app.

| Limit | Value |
| --- | --- |
| Inbound frame | 1 byte to 64 KiB |
| Outbound frame | 32 MiB, the size the Mac reads |
| A started frame, and every write | 10 seconds |
| Handshake answer | 5 seconds, 4 KiB |
| JSON | Strict UTF-8, nesting depth 64, nothing after the value |
| Active requests | 32 per session, request IDs of 1 to 128 characters, no duplicates |

One session is served at a time.

## Differences from iOS

- **Panels** a plugin carries are packaged as Java resources under a folder of the
  app's choosing, with a `files.txt` index (`NectoPluginPanel.resources`), because
  resource folders cannot be listed portably on Android.

## Sample app

`sample` is a Jetpack Compose app with two tabs.

| Tab | Contents | iOS counterpart |
| --- | --- | --- |
| Connection | SDK status, protocol version, stop and start listening | `ConnectionView` |
| About | SDK and protocol versions | `AboutView` |

The custom plugin `plugin-sample` (`com.example.app.state`, `com.example.app.counter`)
carries the same web panel as `ExampleApp`. The build copies it from
`WebPackages/BuiltInPlugins/Plugins`.

## Building

Build the web panels first (`script/build` does), because the sample packages
`plugin-sample`.

```bash
./gradlew build                          # everything (needs Google Maven)
./gradlew -Pnecto.skipAndroid=true test  # JVM modules only
```

minSdk 26, compileSdk 35, Kotlin 2.0.21, AGP 8.7.3, JDK 17.

## Verification

[docs/verification.md](docs/verification.md) lists what the automated tests cover, and
what was checked against a running app.
