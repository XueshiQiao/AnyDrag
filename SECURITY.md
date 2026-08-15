# Security Policy

## Reporting a Vulnerability

**Please do not open a public issue for security problems.** A public issue tells
everyone about the flaw before there is a fix available.

Report it privately instead:

**[Open a private security advisory →](https://github.com/XueshiQiao/AnyDrag/security/advisories/new)**

That form is visible only to you and the maintainer. It creates a private thread
where the fix can be worked out, and it can be published as an advisory once a
patched version has shipped.

If you cannot use that form for any reason, open a normal issue saying only that
you have a security report and would like a private channel — no details — and a
way to reach you will be arranged.

### What to include

The more of this you can provide, the faster it can be confirmed:

- The version of AnyDrag (shown in Settings → About) and your macOS version
- What an attacker gains, and what access they need to start
- Steps to reproduce, or a proof of concept
- Any relevant lines from `~/Library/Logs/AnyDrag/AnyDrag.log`

Please redact anything personal before pasting logs.

### What to expect

AnyDrag is maintained by one person in their spare time, so this is a best-effort
commitment rather than a service-level agreement:

- An acknowledgement that your report was received and read
- An assessment of whether it is reproducible and how serious it looks
- For confirmed issues, a fix in a release, and credit to you in the release notes
  and the published advisory unless you ask to stay anonymous

You are welcome to disclose publicly once a fixed version has shipped.

## Supported Versions

Only the **latest released version** receives security fixes. AnyDrag ships
frequent releases and updates itself through Sparkle, so the practical advice is
to stay on the current version.

| Version | Supported |
| --- | --- |
| Latest release | Yes |
| Anything older | No — please update first and confirm the issue is still present |

## Scope

AnyDrag holds more privilege than a typical menu bar app, so these areas are the
ones genuinely worth attention:

- **The event tap.** AnyDrag requires macOS Accessibility permission and installs
  a `CGEvent` tap, which means it observes mouse and keyboard events system-wide.
  Anything that could turn that into leaking, logging, or forwarding input is a
  serious finding.
- **The update channel.** Updates are delivered through Sparkle from
  `https://github.com/XueshiQiao/AnyDrag/releases/latest/download/appcast.xml`
  and are EdDSA-signed. Anything that could get an unsigned or substituted build
  installed is a serious finding.
- **Synthesized events.** AnyDrag rewrites and posts mouse events to drive window
  drags. Ways to make it act on or inject into another application beyond moving
  a window are in scope.
- **Local privilege and data.** Preferences, logs, and anything AnyDrag writes to
  disk or sends off the machine, including its analytics.

## Not vulnerabilities

To save you the trouble of writing these up:

- **AnyDrag asks for Accessibility permission.** It cannot work without it — that
  permission is what allows an event tap to exist at all. The prompt is macOS
  working as designed, not a flaw.
- **AnyDrag can move windows belonging to other applications.** That is the entire
  purpose of the app.
- Findings from an automated scanner with no demonstrated impact, reports about
  the absence of a hardening flag that macOS does not require for this app type,
  or anything requiring an attacker who already has code execution as your user.
