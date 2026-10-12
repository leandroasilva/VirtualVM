# Security Policy

## Supported Versions

| Version | Supported |
| ------- | --------- |
| Latest  | Yes       |

## Reporting a Vulnerability

If you discover a security vulnerability in VirtualVM, please report it responsibly.

**Do not open a public issue for security vulnerabilities.**

Instead, please use [GitHub's private vulnerability reporting](https://github.com/leandroasilva/VirtualVM/security/advisories/new) to submit your report.

### What to include

- A description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

### What to expect

- Acknowledgment within 48 hours
- A plan for a fix within 7 days for confirmed issues
- Credit in the release notes (unless you prefer to remain anonymous)

## Scope

This policy applies to the VirtualVM app, the `virtualvm` command-line tool, the
guest tools that VirtualVM installs in virtual machines, and the build tooling.
For vulnerabilities in Apple's Virtualization framework or in a guest operating
system, please report them to Apple or to that system's vendor directly.

## How the app runs

- **No App Sandbox, by design.** The app shares `~/.ssh`, binds socket files,
  and talks to `vmnetd`; none of that lives inside a sandbox. It holds only the
  entitlements it needs (`virtualization`, `audio-input`, and USB passthrough
  when a provisioning profile grants it). If you prefer a sandboxed setup, run
  the app inside its own user account rather than asking for a sandbox flag,
  which would leave it unable to do its job.
- **Hardened runtime.** Release builds run with the hardened runtime and are
  notarized. `com.apple.security.cs.disable-library-validation` appears only in
  ad-hoc development copies, which are not releases.
- **Image downloads are verified.** A disk image or installer is kept only if
  its digest matches the checksums published by its vendor; nothing is accepted
  on trust. Apple's restore images carry no published checksum and are instead
  checked against Apple's own signature when loaded.
- **Local control socket.** The `virtualvm` tool reaches the app over a socket
  that only the user who owns it can open (mode `0600`), and the guest agent
  checks the peer's uid before serving anything.
- **Self-updates.** Sparkle updates require an Ed25519 signature made with the
  release key; unsigned or foreign-signed builds are refused.
