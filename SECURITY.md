# Security Policy

## Reporting a vulnerability

Please report privately through GitHub, not in a public issue:

**[Open a private security advisory](https://github.com/scumbly/charopos/security/advisories/new)** — or from the repository's **Security** tab → **Report a vulnerability**.

That channel is private between you and the maintainer, so there's no need to publish anything before there's a fix.

Useful things to include: what an attacker gains, what access they need first, and the shortest path you found to reproduce it. A rough sketch is fine — a working exploit isn't required.

Charopos is a personal project maintained in spare time, so there's no guaranteed response window. Reports are read and taken seriously, and you'll be credited in the fix commit unless you'd rather not be.

## Supported versions

The `main` branch only. Charopos is distributed as source you build yourself, so a fix reaches you with `git pull && ./build.sh` — there are no releases to backport to and no binaries to re-issue.

## Known and accepted risks

These are documented design trade-offs, described in more detail in the README's Security section. Reporting one of them as a vulnerability isn't necessary — but a report that shows one is **worse in practice than described**, or exploitable in a way the README doesn't anticipate, is genuinely useful and very welcome.

- **The control API speaks unencrypted HTTP.** Anyone who can observe traffic on a network where "All interfaces" is enabled can capture the token and gain full control. The mitigation is the "Tailscale only" bind mode, where WireGuard supplies the encryption Charopos doesn't.
- **Credentials are stored unencrypted.** Service API keys and the DSM and Pi-hole passwords live in `~/Library/Application Support/Charopos/config.json`, mode `0600`. Anything running as your user account can read them, and they are copied into Time Machine backups in the clear. The Keychain was considered and rejected: under ad-hoc signing it would prompt on every rebuild, and its prompt-free mode carries the same exposure.
- **The DSM password travels in a URL.** Synology's authentication API takes credentials as query parameters. Certificate pinning stops it being read off the network, but it still reaches the NAS's own webserver access log. Giving Charopos a dedicated, limited DSM account is the practical mitigation.
- **Builds are ad-hoc signed and not notarized.** Gatekeeper cannot verify them; you are trusting the source you cloned.
- **App Transport Security is broadly disabled.** It has to be — Charopos talks to NAS units and consoles serving self-signed certificates at addresses unknowable at build time. Local TLS identity is protected instead by trust-on-first-use certificate pinning (see below). The two internet endpoints the app calls, `api.prowlapp.com` and `api.ipify.org`, are exempted back into strict ATS.
- **Charopos Remote can replace its own application bundle** with a copy fetched from the server, and there is no signature to verify it against. This is restricted to connections over a Tailscale address, where the transport is already authenticated and encrypted; it is refused on any other network.

## What is in scope

The things most worth attacking, and most worth reporting:

- Bypassing API token authentication, or any route that acts without a valid token
- Path traversal or arbitrary file read through the log or dashboard routes
- Command or argument injection through configuration values, service names, or script environment variables
- Defeating the TLS certificate pinning in `CertPinStore` — accepting a changed certificate, or getting a rogue key stored as trusted
- Bypassing the tailnet restriction on the Remote app's self-update
- Secrets appearing somewhere they shouldn't: logs, process arguments, notification payloads, the status API

## What is out of scope

- Anything requiring an attacker to already run code as your user account. The threat model assumes that account is trusted; the config file is deliberately readable by it.
- The accepted risks listed above, as described.
- Findings against third-party software Charopos talks to — Synology DSM, Pi-hole, UniFi, the *arr apps. Report those to their maintainers.
