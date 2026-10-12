# Getting Started

## Requirements

| | |
| --- | --- |
| Mac | Apple silicon |
| macOS | 27 or newer |
| Disk space | A Linux image is under 1 GB. The macOS restore image is about 25 GB. |

## Install

Install with [Homebrew](https://brew.sh):

```bash
brew install --cask leandroasilva/tap/virtualvm
```

Or download it yourself:

1. From the [latest release](https://github.com/leandroasilva/VirtualVM/releases/latest),
   download `VirtualVM-<version>.dmg`.
2. Drag **VirtualVM** to `/Applications` and open it.

The app updates itself, also when installed with Homebrew. See
[Updates](settings.md#updates).

To build it from source instead, see [Building](../tech/building.md).

## The menu bar

VirtualVM lives in the menu bar. There is no main window: click its item to see
your virtual machines, start and stop them, and reach everything else. Each
machine's display opens in a window of its own.

The first time you open VirtualVM, it opens **New Virtual Machine** for you.

## Your first virtual machine

A Linux machine is the quickest start:

1. Choose **New Virtual Machine** in the panel, or press `Cmd+N`, and pick
   **Linux**.
2. Keep **Quick Create** and pick a distribution.
3. Choose **Create**. VirtualVM downloads the image, sets up your account and SSH
   key, and starts the machine.

For macOS, pick **macOS** instead and enter a password for the account. The
download is large, and installing takes a few minutes. See
[macOS guests](../features/macos-guests.md).

## Connect

- **Use the display.** Choose **Open Window** on the machine in the panel.
- **Use SSH.** Choose **Open in Terminal**, or run `virtualvm ssh <machine>`.
  To use plain `ssh <machine>`, turn on **Add machines to ~/.ssh/config** in
  Settings. See [SSH](../features/ssh.md).

## The `virtualvm` command

Homebrew puts `virtualvm` on your `PATH`. If you installed from the DMG, choose
**Settings… → Command Line → Install Command Line Tool…**, which links
`/usr/local/bin/virtualvm`.

```bash
virtualvm create ubuntu-26.04 --name "Web Server"
virtualvm ssh web-server
```

The app must be running. See [Command line](../features/command-line.md).

## Beta

Beta builds get new features first. Download one from the newest
`v<version>-beta.<N>` pre-release on the
[releases page](https://github.com/leandroasilva/VirtualVM/releases). A beta build
updates to each new beta.

## Next

- [Virtual machines](../features/virtual-machines.md): the panel, power, and
  hardware.
- [Linux guests](../features/linux-guests.md) and
  [macOS guests](../features/macos-guests.md).
- [Networking](../features/networking.md), [SSH](../features/ssh.md), and
  [Shared folders and clipboard](../features/sharing.md).
- [Snapshots](../features/snapshots.md).
- [Settings](settings.md) and [Troubleshooting](troubleshooting.md).
