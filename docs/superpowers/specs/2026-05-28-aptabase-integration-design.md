# Aptabase Analytics Integration

**Date:** 2026-05-28
**Status:** Approved

## Goal

Add privacy-friendly usage analytics so we can answer two questions:

1. How many active users does AnyDrag have (DAU/MAU)?
2. Which features are actually used (drag / tile / maximize / middle-click)?

## Non-Goals

- No per-app usage data (no foreground-window bundle IDs, no window titles, no app names).
- No drag duration / distance / coordinate telemetry.
- No PII, no IP geolocation, no device fingerprinting (Aptabase's defaults — we don't add any).

## Provider & Configuration

| Decision | Choice |
|---|---|
| Provider | Aptabase Cloud (official SDK, hosted) |
| SDK | `aptabase/aptabase-swift` via SPM, `from: "0.3.4"` |
| App key | `A-US-7901961627` — embedded in source (client-side keys are not secrets) |
| Region | US (auto-detected by SDK from `A-US-` prefix; no `host` needed) |
| Debug builds | **Tracked.** SDK default `trackingMode: .readFromEnvironment` auto-tags Debug events; Aptabase dashboard splits Debug/Release views. |
| Sandbox entitlement | Not applicable — AnyDrag is non-sandboxed |

## Event Catalog

| Event | When | Properties |
|---|---|---|
| `app_launched` | `applicationDidFinishLaunching` after SDK init | — |
| `update_installed` | First launch after `CFBundleShortVersionString` differs from `Preferences.Key.lastSeenVersion` AND `lastSeenVersion` is non-nil (i.e. not a fresh install) | `from_version`, `to_version` |
| `permission_granted` | First launch where Accessibility permission is observed as granted AND the previous launch's `Preferences.Key.lastPermissionGranted` was `false` | — |
| `drag_performed` | One per completed drag, on drag END | `trigger` (`"modifier"` or `"middle"`), `modifier` (e.g. `"option"`; `""` when `trigger="middle"`) |
| `maximize_performed` | When double-click-with-modifier maximize/restore fires | — |
| `tile_performed` | Any tile application (panel or middle-direction) | `tile` (canonical lowercase string, see mapping below), `trigger` (`"panel"` or `"middle_direction"`) |
| `preference_changed` | After a Preferences setter writes a NEW value (compare before write) | `key` (one of `"modifier"`, `"drag_enabled"`, `"maximize_enabled"`, `"tiling_enabled"`, `"middle_action"`, `"language"`, `"analytics_enabled"`), `value` (stringified) |

**Notes on `preference_changed`:**

- The `analytics_enabled` toggle **is** tracked as a `preference_changed` event in BOTH directions (ON→OFF and OFF→ON). Implementation: `Analytics.trackPreferenceChanged` bypasses the opt-out gate ONLY when `key == "analytics_enabled"` — otherwise the OFF→ON re-enable could never be observed, and we want to see the full opt-out funnel for product decisions. This is the single intentional exception to the gating rule and is documented at the call site.
- `modifier`'s `value` is the canonical string form of `ModifierCombination` (e.g. `"option"`, `"control"`, `"option+command"`, `""` for empty). Lowercase, `+`-joined, alphabetical order.

**Tile string mapping** (used by `tile_performed.tile`):

| Source enum | Variant | String |
|---|---|---|
| `TileAction` (panel) | `.leftHalf`, `.rightHalf`, `.topHalf`, `.bottomHalf` | `"left_half"`, `"right_half"`, `"top_half"`, `"bottom_half"` |
| `TileAction` (panel) | `.topLeft`, `.topRight`, `.bottomLeft`, `.bottomRight` | `"top_left"`, `"top_right"`, `"bottom_left"`, `"bottom_right"` |
| `TileAction` (panel) | `.fill`, `.fillRight`, `.leftAndRight`, `.quarters` | `"fill"`, `"fill_right"`, `"left_and_right"`, `"quarters"` |
| `TileZone` (middle direction) | `.full`, `.centered` | `"fill"`, `"centered"` |
| `TileZone` (middle direction) | `.left`, `.right` | `"left_half"`, `"right_half"` |
| `TileZone` (middle direction) | `.topLeft`, `.topRight`, `.bottomLeft`, `.bottomRight` | `"top_left"`, `"top_right"`, `"bottom_left"`, `"bottom_right"` |

**Volume note.** `drag_performed` dominates — heavy users may fire it hundreds of times/day. Aptabase Cloud paid tiers absorb this. If quota becomes a concern, the throttling path is "1 `drag_performed` per `{session, modifier}` tuple"; do not pre-optimize.

## Opt-Out UX

- New pref: `Preferences.Key.analyticsEnabled : Bool`, default `true`.
- **Settings → Advanced** gains a toggle row:
  - Label: `Send anonymous usage data`
  - Subtitle: `Anonymous events about launches and feature usage. No personal data, IP addresses, app names, or window contents are collected.`
- **Settings → About** gains a footer line:
  - `Anonymous usage statistics are sent via Aptabase. Disable in Settings → Advanced.`
- All `Analytics.track*` helpers gate on `Preferences.analyticsEnabled` — flipping the toggle off causes future events to be dropped immediately at the call site.

Opt-out is **not** implemented as `Aptabase.shared.stopSession()` because that API does not exist in the public SDK; client-side gating is the documented pattern.

## Architecture

New file `Sources/Analytics.swift` — single static facade so call sites never import `Aptabase` directly:

```swift
import Aptabase
import AppKit

enum Analytics {
    static func start()                                          // init + appLaunched + updateInstalled
    static func flush()                                          // applicationWillTerminate
    static func trackPermissionGranted()
    static func trackDrag(modifier: ModifierCombination)
    static func trackMaximize()
    static func trackTile(_ kind: TileKind)                      // TileKind exists in TilingPanel
    static func trackMiddleAction(_ action: MiddleAction)
    static func trackPreferenceChanged(key: String, value: String)
}
```

Every public function checks `UserDefaults.standard.bool(forKey: Preferences.Key.analyticsEnabled)` (with default `true` if absent) and returns early if disabled. `start()` performs the init exactly once.

## Files Touched

- `project.yml` — add Aptabase SPM package + target dep
- `AnyDrag/Sources/Analytics.swift` — **NEW**
- `AnyDrag/Sources/Preferences.swift` — add `analyticsEnabled`, `lastSeenVersion`, `lastPermissionGranted` keys; helper that returns the default for `analyticsEnabled`
- `AnyDrag/Sources/AppDelegate.swift` — call `Analytics.start()` in `applicationDidFinishLaunching`; `Analytics.flush()` in `applicationWillTerminate`
- `AnyDrag/Sources/PermissionManager.swift` — call `Analytics.trackPermissionGranted()` on first-grant detection
- `AnyDrag/Sources/DragEngine.swift` — fire `trackDrag`, `trackMaximize`, `trackMiddleAction` from existing event hooks
- `AnyDrag/Sources/TilingPanel.swift` — fire `trackTile(_:)` when a tile is applied
- `AnyDrag/Sources/Settings/AdvancedPaneViewController.swift` — opt-out toggle row + binding
- `AnyDrag/Sources/Settings/AboutPaneViewController.swift` — disclosure footer
- `AnyDrag/Resources/en.lproj/Localizable.strings` — new strings
- `AnyDrag/Resources/zh-Hans.lproj/Localizable.strings` — new strings

## Testing

Manual (no test target exists for AnyDrag):

1. DEBUG build + launch → verify `app_launched` appears in Aptabase dashboard's **Debug** view.
2. Drag + tile + middle-click + change a preference → verify each event fires once.
3. Toggle "Send anonymous usage data" OFF in Settings → Advanced → verify subsequent actions produce no new events.
4. Toggle back ON → verify events resume.
5. Bump `CURRENT_PROJECT_VERSION`/`MARKETING_VERSION` locally, rebuild, launch → verify `update_installed` fires exactly once with the right `from_version` / `to_version`.
6. Revoke Accessibility permission in System Settings, relaunch, re-grant → verify `permission_granted` fires once on re-grant.
