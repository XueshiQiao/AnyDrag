---
name: release
description: Cut a new AnyDrag release end-to-end — bump version, write bilingual notes, tag, watch CI, bump Homebrew cask, close referenced issues.
argument-hint: <new-version> (e.g. 1.2.5)
disable-model-invocation: true
---

# Release AnyDrag $ARGUMENTS

End-to-end release routine for AnyDrag. Owns the full chain from version bump through Homebrew cask publication. Treat each numbered phase as a checkpoint — show the user what you're about to do, then execute.

## Phase 0 — Validate input and survey state

1. Validate `$ARGUMENTS` is a semver string `X.Y.Z`. If missing or malformed, ask.
2. Read current `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` from `project.yml`. The new build number = current + 1 (Sparkle requires it to monotonically increase — see memory `feedback_version_bump`).
3. `git status` — bail if there are uncommitted changes that aren't yours to ship.
4. `git log --all --oneline -10` — list any local-only feature branches whose commits aren't on `main` yet. Surface them to the user and ask whether to land them in this release. If yes, **cherry-pick** them onto `main` (preserves linear history matching existing log style).
5. `gh issue list --repo XueshiQiao/AnyDrag --state open` — note any open issues that the new release likely closes (feature requests, bug reports). You'll close these in Phase 6.

## Phase 1 — Bump version in `project.yml`

Edit `project.yml`:
- `MARKETING_VERSION: "<old>"` → `MARKETING_VERSION: "$ARGUMENTS"`
- `CURRENT_PROJECT_VERSION: "<old>"` → `CURRENT_PROJECT_VERSION: "<old+1>"`

## Phase 2 — Cumulative release notes in every supported language

Edit `RELEASE_NOTES.html` at repo root (CI's "Generate Release Notes" step prefers this file over auto-generation; if it doesn't exist, CI falls back to `gh api ... generate-notes` which produces EN-only generic text).

**Discover supported languages** by scanning the app's localization sources — never hardcode the language list. Run:

```bash
find AnyDrag/Resources -type d -name "*.lproj" -mindepth 1 -maxdepth 2 \
  | sed 's|.*/||;s|\.lproj$||' | sort -u
```

If the app uses `Localizable.xcstrings` instead of `.lproj` folders, parse the `localizations` keys from that JSON. Either way, derive the full language list from source — every language the app ships UI in must get a section, no exceptions.

**One `<h3>` + `<ul>` block per language**, in the order Apple lists them in the app's `Info.plist` or asset catalog (CFBundleLocalizations / xcstrings localizations), with English first as the lingua franca. Use the language's own native name in the heading (English / 简体中文 / 日本語 / Deutsch / …).

```html
<h3>What's New in X.Y.x</h3>
<ul>
  <li><b>Feature name</b> — Plain-English description, ≤2 sentences. Credit contributors with @handle.</li>
  ...
</ul>

<h3>X.Y.x 更新内容</h3>
<ul>
  <li><b>功能名称</b> — 简体中文描述。贡献者用 @handle 标注。</li>
  ...
</ul>

<!-- Repeat for every additional language from the .lproj scan above -->
```

The HTML body lands inside Sparkle's `<description><![CDATA[…]]></description>` and is rendered in the in-app update dialog — every section is shown to every user regardless of system language, so write each one as if it's the only one a particular reader will understand.

**Cumulative rule:** for a minor version like 1.2.4, list all changes since the last MAJOR version (1.2.0), not just since the last patch. Users often skip patches.

To gather the changeset: `git log <last-major-tag>..HEAD --no-merges --pretty=format:"- %s%n%b%n---"` — read the actual commit bodies to write accurate notes (don't just copy commit subjects).

**Translation accuracy:** if you write the EN copy yourself, write each other language directly rather than translating word-for-word. Mirror the structure (same bullets, same order, same `<b>` headers) but use natural phrasing in each target language. If a contributor's `@handle` appears in EN, keep it identical in every other language — it's a GitHub URL, not a translatable string.

## Phase 3 — Commit, tag, push (triggers CI)

**Ordering matters.** If origin has moved while you were preparing the release (CI pushed the previous release's appcast, or someone else pushed), you MUST rebase **before** tagging — tags don't follow rebase. See the "Tags don't follow rebase" gotcha below for the failure mode.

The safe sequence:

```bash
# 1. Stage the release commit
git add project.yml RELEASE_NOTES.html
git commit -m "Release X.Y.Z: <one-line summary of headline features>"

# 2. Sync with origin BEFORE tagging
git fetch origin
git pull --rebase origin main      # no-op if you're already up-to-date

# 3. Tag AFTER rebase, on the up-to-date HEAD
git tag vX.Y.Z

# 4. Sanity check: tag and HEAD must point to the same commit
[ "$(git rev-parse vX.Y.Z)" = "$(git rev-parse HEAD)" ] || echo "TAG MISMATCH — DO NOT PUSH"

# 5. Push main first, then tag — gives CI a clean view
git push origin main
git push origin vX.Y.Z
```

Tagging triggers `.github/workflows/build.yml` which: builds → signs → notarizes → staples → creates DMG → signs DMG with Sparkle EdDSA → writes `appcast.xml` (using `RELEASE_NOTES.html`) → commits appcast back to `main` → publishes GitHub Release with the DMG attached.

## Phase 4 — Watch CI

Poll `https://api.github.com/repos/XueshiQiao/AnyDrag/actions/runs?per_page=5` for the run whose `head_branch == "vX.Y.Z"`. Run a background bash with a polling loop and `run_in_background: true` — you'll be notified on completion. Do NOT busy-poll.

If `conclusion != "success"`, stop and report failure. Don't proceed to cask bump on a failed build.

## Phase 5 — Bump the Homebrew cask

The cask lives in the user's shared tap repo: **`https://github.com/XueshiQiao/homebrew-tap`**, locally at **`~/Code/homebrew_tap`** (note underscore — GitHub redirects to hyphenated canonical URL; remote URL still uses underscore).

The same tap also hosts casks for hypercapslock, netstat-cat, notifier, pastepaw — don't touch those. Only edit `Casks/anydrag.rb`.

```bash
# 1. Sync local clone
cd ~/Code/homebrew_tap
git pull --ff-only origin main

# 2. Compute sha256 of the new DMG
DMG_URL="https://github.com/XueshiQiao/AnyDrag/releases/download/vX.Y.Z/AnyDrag.dmg"
curl -sL "$DMG_URL" -o /tmp/AnyDrag-X.Y.Z.dmg
SHA=$(shasum -a 256 /tmp/AnyDrag-X.Y.Z.dmg | awk '{print $1}')

# 3. Edit Casks/anydrag.rb — bump version + sha256 only.
#    The url uses #{version} interpolation, no manual edit needed.

# 4. Validate
brew style ~/Code/homebrew_tap/Casks/anydrag.rb

# 5. Commit + push (style matches existing commits: "Update cask for anydrag vX.Y.Z")
cd ~/Code/homebrew_tap
git add Casks/anydrag.rb
git commit -m "Update cask for anydrag vX.Y.Z"
git push origin main
```

Verify the public install actually works:

```bash
brew update                                       # syncs the new commit
brew install --cask XueshiQiao/tap/anydrag        # 3-segment auto-tap form
/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' /Applications/AnyDrag.app/Contents/Info.plist  # → X.Y.Z
spctl -a -t exec -vv /Applications/AnyDrag.app    # → Notarized Developer ID
brew uninstall --cask anydrag                     # leave clean state
```

## Phase 6 — Close referenced issues

For each issue identified in Phase 0:

```bash
gh issue close <N> --repo XueshiQiao/AnyDrag \
  --comment "Released in [vX.Y.Z](https://github.com/XueshiQiao/AnyDrag/releases/tag/vX.Y.Z). <One-line how-to-use, optionally @-thank contributors.>"
```

If an issue was already auto-closed (commit message containing `(#N)` doesn't auto-close, but the user may have closed it manually), still leave a release-link comment with `gh issue comment <N> --body "..."` so the trail is complete.

## Phase 7 — Final report

Report to the user:
- Release URL, CI run URL.
- Cask commit URL on `homebrew-tap`.
- Issues closed with their numbers and one-line summaries.
- Any deltas from a clean run (e.g., CI retried, cask audit warnings, issues that resisted closing).

---

## Constraints and gotchas

- **Don't merge feature branches via PR for solo releases.** `git cherry-pick` keeps the linear history that matches existing commit log style.
- **Build number must increase every release** (memory `feedback_version_bump`). Sparkle compares `CFBundleVersion`, not `CFBundleShortVersionString`, to decide whether to offer an update.
- **Tags don't follow rebase.** Hit live in 1.3.1: pre-release prep had a `git pull --rebase` *after* `git tag vX.Y.Z`, so the tag stayed at the pre-rebase orphan commit. Pushing it triggered CI; the build/sign/notarize/DMG steps all succeeded, but the "Sign DMG and Generate Appcast" step's final `git push origin HEAD:main` failed with `! [rejected] HEAD -> main (fetch first)` — the orphan commit's history didn't include origin/main's actual head. Because the GitHub Release creation runs *after* that push, the release was never created and `gh release view` returned "release not found". **Recovery**: delete the bad tag locally and remotely (`git push origin :refs/tags/vX.Y.Z; git tag -d vX.Y.Z`), retag at the correct post-rebase commit, push again. **Prevention**: tag *after* rebase, and always run the `[ "$(git rev-parse vX.Y.Z)" = "$(git rev-parse HEAD)" ]` sanity check before pushing the tag.
- **Pre-flight permission prompts on a clean state.** Your dev machine has already granted permissions a fresh user hasn't. Before tagging a release, **install the build into `/Applications` and launch as if you were a new user** — observe which permission prompts macOS actually shows. AnyDrag should only request Accessibility. Hit live in 1.3.0/1.3.1: a probe added to detect AX revocation listened for `keyDown` events, which made macOS prompt for **Input Monitoring** even though AnyDrag never reads keyboard input. The bug shipped because dev had previously granted Input Monitoring incidentally and never saw the prompt. **Code-level prevention**: when creating event taps for permission probing, use only the minimum capability the app actually needs (mouse for AnyDrag, never keyboard).
- **Don't try to install a cask via raw URL or 2-segment tap form.** `brew install --cask https://...rb` and `brew install --cask user/repo` both fail in modern brew — see memory `feedback_brew_install_form`. Only the 3-segment form `XueshiQiao/tap/anydrag` works for this user's setup.
- **Don't put the cask file in the AnyDrag main repo.** It belongs in `homebrew-tap`. The skill `macos-app-scaffold-enhance`'s template wrongly puts it in `Casks/` of the app repo — that won't install.
- **`gh` is at `/opt/homebrew/bin/gh`.** PATH may not include it depending on shell setup; use the absolute path if `which gh` fails.
- **Codex review** per global rule: invoke after Phase 5 completes, scope = files touched in this release. Skip only if user has explicitly said "ignore codex" in this session.
