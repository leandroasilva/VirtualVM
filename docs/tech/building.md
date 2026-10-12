# Building

Building the app, running a development copy, and signing.

## Requirements

- macOS 27 or newer, on Apple silicon
- Xcode 27 or newer

No Apple Developer account is needed to build and run virtual machines.

## Build

```bash
git clone https://github.com/leandroasilva/VirtualVM.git
cd virtualvm
scripts/build.sh          # the app, optimized, at build/VirtualVM.app
open build/VirtualVM.app
```

There is no Xcode project. The app is a Swift package: `swift build` compiles
it, and `scripts/bundle-app.sh` makes an app of the result and signs it. Xcode
opens `Package.swift`.

| Command | What it does |
| --- | --- |
| `scripts/build.sh` | Builds the app at `build/VirtualVM.app`, with `virtualvm` and the macOS guest agent inside |
| `scripts/build.sh debug` | The same, not optimized |
| `scripts/build.sh --output <app>` | Builds somewhere else, for example while VirtualVM is running from `build/` |
| `scripts/test.sh` | Runs the unit tests of both packages |

The scripts never replace an app that is running.

## The development copy

```bash
swift run VirtualVM
```

This builds and opens **VirtualVM Dev**, an app of its own to macOS. It keeps its
machines in `~/Library/Application Support/VirtualVM-Dev`, so it runs next to the
VirtualVM you use and never sees that app's machines.

- The copy is at `.build/VirtualVM Dev.app`, and its tool talks to that copy:
  `".build/VirtualVM Dev.app/Contents/Helpers/virtualvm" list`.
- The command stays in the terminal and shows what the copy prints. `Ctrl+C`
  asks the copy to quit, which it refuses while a machine is running. A second
  `Ctrl+C` leaves it running.
- `swift run VirtualVM --background` opens the copy behind your other windows
  and returns.
- Running the command again replaces a copy that is still open, unless it has
  a machine running.
- The two apps share the downloaded images, the SSH key VirtualVM makes, and the
  `virtualvm` link in `/usr/local/bin`.
- The development copy doesn't update itself.

Set `VIRTUALVM_HOME` to give a copy another data folder, for a second set of
machines. The path must be short, about 90 characters at most, and `virtualvm`
needs the same setting to find that copy.

## Signing

With a signing certificate in your keychain, the app is signed with it:
Developer ID Application before Apple Development, and the other way round for
the development copy. Without one, the app is signed to run on your Mac, which
is enough to run virtual machines.

| Variable | What it does |
| --- | --- |
| `VIRTUALVM_SIGN_IDENTITY` | Picks a certificate by name or SHA-1. `-` signs to run on your Mac |
| `VIRTUALVM_PROVISIONING_PROFILE` | Names a provisioning profile to use. `-` builds without one |
| `VIRTUALVM_HOME` | Another data folder for the app and for `virtualvm` |

## USB devices

Handing [USB devices](../features/usb-devices.md) to guests is the one thing
that takes more than a certificate. macOS only allows it in an app that carries
a provisioning profile:

- Made in a paid Apple Developer account, for the app's identifier, with the
  **Claim USB Accessory** capability.
- For the certificate the app is signed with: a Developer ID profile for
  `com.virtualvm.app`, or a development profile that lists your Mac for
  `com.virtualvm.app.dev`.

The build looks for such a profile where Xcode keeps profiles and puts it into
the app. When there is none, it says so and builds without: everything works
but USB devices, and the USB button isn't shown.

## Building only the tool

```bash
swift build --package-path Packages/VirtualVMKit --product virtualvm
```

Never build `virtualvm` at the repository's root. The file system takes `virtualvm`
and `VirtualVM` for one name, and the tool would replace the app's program.

## Layout

| Path | What |
| --- | --- |
| `Package.swift`, `App/` | The SwiftUI app |
| `Tests/VirtualVMTests/` | The app's unit tests |
| `Packages/VirtualVMKit/` | The engine, the `virtualvm` tool, and the guest agents, with their tests. See [Architecture](./architecture.md#modules) |
| `Config/` | The app's `Info.plist` and entitlements |
| `scripts/` | Build, test, and release scripts |
| `.github/workflows/` | Checks and [releases](./releasing.md) |
| `assets/` | The logo |
| `docs/` | These docs |
