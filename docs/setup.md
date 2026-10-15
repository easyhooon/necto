# Setting up Necto in an app

Necto's SDK is a debug tool that compiles into your app. This page covers integrating
the SDK and excluding its calls from production builds. Install the Mac app separately
using [install.md](install.md).

## Wiring it up

Add `https://github.com/toss/necto.git` in Xcode's Package Dependencies.
Select the `NectoSDK` product for your app target. It includes the SDK and built-in
plugin modules; keep the imports for the modules you use, as shown below.
Register the plugins once during app startup, then start the SDK:

```swift
import NectoDefaultPlugins
import NectoProcessMetrics
import NectoSDK
import NectoURLSessionCapture

#if DEBUG
let events = NectoEventsPlugin()
NectoSDK.register(URLSessionNetworkPlugin())   // network, captured for you
NectoSDK.register(events)
NectoSDK.register(ProcessPerformancePlugin())  // six process metrics while observed
NectoSDK.register(NectoUIControlPlugin())
NectoSDK.start()
events.report(NectoEvent(level: .info, tag: "App", message: "App started"))
#endif
```

Register only the plugins you need. Adding the package does not register plugins,
start a listener or enable capture. Built-in plugin code and panel resources are
included in the product even if you do not register them.
Your own plugins register the same way; their panels appear
in Necto when the app connects. See [the device plugin tutorial](tutorial-device.md)
for a complete implementation.

### Updating existing dependencies

If your app or plugin package explicitly depends on `NectoDefaultPlugins`,
`NectoProcessMetrics`, `NectoURLSessionCapture`, `NectoModel` or `NectoTransport`
products, replace those product dependencies with `NectoSDK`. In a `Package.swift`:

```swift
.product(name: "NectoSDK", package: "necto")
```

The module names, imports and registration APIs are unchanged. This is a package
configuration change: manifests referencing the old products must be updated before
adopting the new version. Mac host products now live in the local `NectoMac` package and
are not part of the SDK.

## Keeping it away from users

Do not run debugging tools in builds distributed to users.

> Wrap every Necto call in `#if DEBUG`.

Calls inside `#if DEBUG` are excluded when `DEBUG` is not defined. Check that your
Release build settings do not define `DEBUG`.

The built-in UI Control provider synthesizes touches using private UIKit and
IOHID entry points. Its Swift implementation lives in `NectoDefaultPlugins` and
resolves selectors and C functions at runtime instead of linking Objective-C
private method declarations. It supports positioned taps, 1–5 simultaneous fingers,
1–3 successive taps, swipes, and edge-back gestures. Native controls and text inputs
are discovered through public UIKit properties. SwiftUI support additionally enables
application accessibility through `_AXSApplicationAccessibilitySetEnabled` and
routes each touch through `_UIHitTestContext`, `_hitTestWithContext:` and
`_setResponder:`. These use the same runtime symbol resolver; there is no separate
`libAccessibility.dylib` load or `_accessibilityInit` call. If these runtime entry
points are missing, SwiftUI target discovery or touch delivery may be unavailable.
Runtime lookup does not make these APIs public.
Missing required touch entry points return `OPERATION_UNAVAILABLE`. OS changes can still
break the implementation, and Swift cannot catch Objective-C exceptions.

Runtime lookup is not a guarantee of App Store Connect or TestFlight acceptance.
Inspect the final app and embedded frameworks, and keep the debugging tool out of
builds distributed to users.

`NectoSDK.start()` starts the listener. However, `URLSessionNetworkPlugin` starts
capture when registered, so guard plugin creation and registration as well as `start()`.

Excluding calls does not guarantee removal of all package code and resources.
What remains depends on linking and build settings such as dead-code stripping.
If complete exclusion is required, use a separate distribution target without Necto
dependencies and inspect the actual Release output for remaining code and resources.
`EXCLUDED_SOURCE_FILE_NAMES` alone does not exclude Swift package sources.

## What connecting involves

- **Simulator**: the Mac reaches the app over loopback.
- **Device**: over the USB cable, through `usbmuxd`.
- The SDK listens on a local TCP port. If another simulator app holds it, the SDK
  looks for a free port within its port range. Necto does not use Bonjour or multicast.
- Two apps, or the same app on two devices, connect side by side and are told
  apart in the sidebar and in `necto-cli` (`--app`, `--device`).

## Where to start

Start with `URLSessionNetworkPlugin` and `NectoEventsPlugin`. Network requests appear
as they happen. Keep the registered `events` instance in your app's debug logging code
and call `events.report(...)` to send log entries, as in the example above. Guard these
calls with `#if DEBUG` too. Add other plugins for the data you need to inspect.

### Which requests are captured

Registering `URLSessionNetworkPlugin` captures `URLSession.shared`. A session your app
builds from a `URLSessionConfiguration` takes its protocols from that configuration,
`.default` included, so its requests appear only once the capture is added to it. That
includes networking libraries that create a session of their own:

```swift
let configuration = URLSessionConfiguration.default
#if DEBUG
configuration.protocolClasses = [NectoURLSessionCapture.protocolClass]
    + (configuration.protocolClasses ?? [])
#endif
let session = URLSession(configuration: configuration)
```

A captured request is re-issued through a session of Necto's own, and its response is
handed back as it arrives. What that changes for a session you add the capture to:

- **Cookies** are handled for `URLSession.shared` through the shared store, as that
  session does itself. What your own configuration says about cookies cannot be seen
  from the capture, so for a session you add it to, no cookie is sent or stored while
  it is captured — a session that relies on cookies sees them stop.
- **Credentials** come from the shared credential store.
- **Caching** is off: a captured request always loads.
- **Redirects** are followed without asking your session's delegate, so a delegate
  that refuses a redirect or changes the redirected request has no effect.
- **Authentication challenges** are not passed to your delegate. A server certificate it
  would accept or pin, and credentials it would supply, do not apply to a captured
  request, so a development server with a self-signed certificate fails.
