---
name: release
description: Cut a new AnyDrag release end-to-end — write cumulative bilingual notes, run bump-version.sh, watch CI, verify Homebrew cask cascade.
disable-model-invocation: true
---

# Release AnyDrag

End-to-end release routine. Owns the full chain from notes through Homebrew cask propagation. Treat each numbered phase as a checkpoint — show your human partner what you're about to do, then execute.

The release flow shares conventions with the HyperCapslock project (`.claude/skills/release/SKILL.md` there): cumulative HTML release notes, bare-@mention contributor credit, `repository_dispatch` to shared tap. The generalized blueprint is documented in `XueshiQiao/macos-app-scaffold`.

## Phase 0 — Validate state

1. `git status` — bail if there are uncommitted changes that aren't yours to ship.
2. `git log --all --oneline -10` — list local-only branches whose commits aren't on `main` yet. **Cherry-pick** (not merge) if you want them in this release; that preserves the linear history of `chore(release): YY.MM.<build>` + `Update appcast for vYY.MM.<build>` (CI bot) + `Update cask for anydrag` (tap bot) commits.
3. `gh issue list --repo XueshiQiao/AnyDrag --state open` — note any open issues that the new release likely closes. You'll close these in Phase 6.

## Phase 1 — Prepend this version's notes to `RELEASE_NOTES.html`

The file is cumulative — every past version stays in it. You add a NEW per-version block at the TOP. Two `<h3>` sections, EN first then `更新内容` (matched by the heading shape the CI extractor + Sparkle appcast both rely on).

**Pick the version first** (it determines the heading text). CalVer is `YY.MM.<build>`:
- `YY.MM` = current UTC year + month (e.g. `26.05`).
- `<build>` = current `CURRENT_PROJECT_VERSION` in `project.yml` + 1.

Then prepend:

```html
<h3>What's New in YY.MM.<build></h3>
<ul>
  <li><b>Feature name</b> — Plain-English description, ≤2 sentences. Credit contributors with a BARE @handle (not an <a> link — see below).</li>
  ...
</ul>

<h3>YY.MM.<build> 更新内容</h3>
<ul>
  <li><b>功能名称</b> — 简体中文描述。贡献者用 @handle 标注（同样裸写，不要包 <a>）。</li>
  ...
</ul>
```

**Contributor credit convention:** write a **bare** `@handle`, not `<a href="...">@handle</a>`. CI uses each version's section as the GitHub Release body; a bare handle lands the contributor in the release's **Contributors** avatar list and gets autolinked. A handle wrapped in `<a>` is skipped by GitHub's autolinker, so neither happens. Renders as plain text in Sparkle — acceptable. `#N` issue/PR refs CAN stay as `<a>` links so they're clickable inside Sparkle too.

**Notification:** a release-body @mention is **credit, not a notification** — GitHub doesn't reliably ping. The reliable ping happens in the Phase 6 issue comment, which must @mention them.

**Translation accuracy:** write each language directly, don't translate word-for-word. Mirror structure (same bullets, same order, same `<b>` headers), but use natural phrasing per locale. The `@handle` stays identical across languages — it's a handle, not text.

Leave the edited `RELEASE_NOTES.html` **uncommitted** — Phase 2's script folds it into the release commit.

## Phase 2 — `scripts/bump-version.sh` (no `--push`)

```bash
scripts/bump-version.sh
```

What it does:
- Computes the new version from `YY.MM.<cur_build+1>`.
- Refuses to run if the working tree has changes other than `RELEASE_NOTES.html`. (Uncommitted notes edits are expected and welcome.)
- Warns if `RELEASE_NOTES.html` has no block for the new version yet (Phase 1 not yet done — fix it before continuing).
- Edits `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`.
- Stages `project.yml` + `RELEASE_NOTES.html` and commits with message `chore(release): YY.MM.<build>`, then tags `vYY.MM.<build>`.

Do NOT pass `--push` yet — sanity-check first.

## Phase 3 — Sanity-check then push

```bash
# Confirm what was bumped + tagged matches HEAD.
git show --stat HEAD
git tag --points-at HEAD     # → vYY.MM.<build>

# Tag MUST point at the same commit as HEAD; if not, fix before pushing.
[ "$(git rev-parse "vYY.MM.<build>")" = "$(git rev-parse HEAD)" ] || echo "TAG MISMATCH — DO NOT PUSH"

# Push main first, then the tag — gives CI a clean view.
git push origin main
git push origin vYY.MM.<build>
```

Tagging triggers `.github/workflows/build.yml` which: builds universal → signs (inside-out, including embedded Sparkle.framework) → notarizes → staples → DMG → signs DMG with Sparkle EdDSA → writes `appcast.xml` (embeds the WHOLE `RELEASE_NOTES.html` into `<description>` CDATA) → commits `appcast.xml` back to `main` (for legacy users still pinned to the raw.githubusercontent URL) → uploads `appcast.xml` + `latest.json` + DMG as release assets (so the new `releases/latest/download/appcast.xml` URL also resolves) → extracts this version's section into `release_body.html` → publishes GitHub Release with that as the body → fires `repository_dispatch` to `XueshiQiao/homebrew_tap` (event `update_cask`).

**Gotcha — tags don't follow rebase.** Hit live in earlier releases: pre-release prep had a `git pull --rebase` *after* `git tag`, so the tag stayed at the pre-rebase orphan commit. Pushing it triggered CI, the build/sign/notarize/DMG steps all succeeded, but the appcast step's final `git push origin HEAD:main` failed with `! [rejected] HEAD -> main`, the GitHub Release was never created, and `gh release view` returned "release not found." Recovery: delete the bad tag locally and remotely (`git push origin :refs/tags/vX; git tag -d vX`), retag at the correct commit, push again. **Prevention**: tag *after* rebase (which `bump-version.sh` enforces by requiring a clean tree minus `RELEASE_NOTES.html`), and run the sanity-check above before pushing.

## Phase 4 — Watch CI

```bash
RUN=$(gh run list --repo XueshiQiao/AnyDrag --workflow build.yml --limit 5 --json databaseId,headBranch --jq '.[] | select(.headBranch=="vYY.MM.<build>") | .databaseId' | head -1)
gh run watch "$RUN" --repo XueshiQiao/AnyDrag --exit-status
```

If conclusion isn't `success`, stop and report. The cascades in Phase 5 won't fire on a failed build.

## Phase 5 — Verify the cask cascade (now automatic)

**Don't manually bump the cask.** The release workflow's `Trigger Homebrew Tap Update` step fired the dispatch. Verify:

```bash
# Tap regeneration of Casks/anydrag.rb
gh run list --repo XueshiQiao/homebrew_tap --workflow update-casks.yml --limit 1 \
  --json status,conclusion,createdAt,displayTitle
gh api repos/XueshiQiao/homebrew_tap/contents/Casks/anydrag.rb --jq '.content' | base64 -d | head -4
```

Should be `completed` / `success` within a few minutes after the AnyDrag CI completes.

Requirements (one-time setup, already in place on this repo):
- `HOMEBREW_TAP_PAT` secret — PAT with `Contents: Read and write` on `XueshiQiao/homebrew_tap`.

The workflow prints an explicit `::warning::` if the PAT is missing, so silent-skip is detectable.

To re-fire a missed dispatch manually:

```bash
gh workflow run update-casks.yml --repo XueshiQiao/homebrew_tap -f app_token=anydrag
```

**The auto-generated cask omits the historical `zap trash:` block.** The shared generator template doesn't model zap paths; `brew uninstall --cask anydrag --zap` won't sweep `~/Library/Application Support/AnyDrag`, etc. Acceptable trade-off for the simpler-cask story; if it ever matters, extend `generate_homebrew_casks.py` to accept an optional `zap_paths` list in `apps.yml`.

Verify the public brew install actually works:

```bash
brew update
brew install --cask XueshiQiao/tap/anydrag
/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' /Applications/AnyDrag.app/Contents/Info.plist  # → YY.MM.<build>
spctl -a -t exec -vv /Applications/AnyDrag.app    # → Notarized Developer ID
brew uninstall --cask anydrag                     # leave clean state
```

## Phase 6 — Close referenced issues, ping reporters

For each issue identified in Phase 0:

```bash
gh issue close <N> --repo XueshiQiao/AnyDrag \
  --comment "Released in [vYY.MM.<build>](https://github.com/XueshiQiao/AnyDrag/releases/tag/vYY.MM.<build>). <One-line how-to-use.> @reporter thanks for the report!"
```

**@-mention the reporter here.** This is the reliable contributor notification (release-body mentions only add a Contributors avatar — they don't ping). An issue comment notifies the issue's author/participants regardless, and the explicit @mention makes the credit unambiguous.

## Phase 7 — Final report

Tell your human partner:
- Release URL, CI run URL.
- Tap workflow run URL + commit on `homebrew_tap`.
- Issues closed with their numbers and one-line summaries.
- Any deltas from a clean run.

---

## Constraints and gotchas

- **Build number must increase every release** (`CURRENT_PROJECT_VERSION`). Sparkle compares `CFBundleVersion`, not `CFBundleShortVersionString`, to decide "is this newer." `bump-version.sh` is the single touchpoint; never hand-edit.
- **Tags don't follow rebase** — see Phase 3 gotcha block.
- **`RELEASE_NOTES.html` stays HTML — don't "upgrade" it to JSON/YAML.** It's not an internal data file; it's the rendered payload shown to end users in two places. Sparkle's update dialog renders the HTML natively (it's the appcast `<description>` CDATA), and GitHub renders the inline HTML in the Release body. JSON/YAML can't be displayed to users.
- **`SUFeedURL` is currently the releases-asset URL (`/releases/latest/download/appcast.xml`)** — the HCL pattern, the cleaner one. v1.4.x users still update successfully because CI keeps dual-publishing (the legacy `Sign DMG and Generate Appcast` step still commits `appcast.xml` back to `main`, so `raw.githubusercontent.com/.../main/appcast.xml` keeps resolving). Once telemetry says everyone is past v1.4.x, the legacy commit-to-main step can be retired.
- **Don't put the cask file in this repo.** It belongs in `XueshiQiao/homebrew_tap`, auto-generated by that repo's `update-casks.yml` workflow from the `latest.json` this release publishes. See the macos-app-scaffold blueprint for the full pipeline.
- **`.agents/skills/release/SKILL.md` is stale (pre-CalVer-migration).** This file (`.claude/skills/release/SKILL.md`) is the source of truth. If your human partner wants the `.agents/` mirror back in sync, either symlink it or copy the content over.
- **Codex review** per global rule: invoke after Phase 5 verifies, scope = files touched in this release. Skip only if the user has explicitly said "ignore codex" in this session.
