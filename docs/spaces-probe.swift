// spaces-probe.swift — evidence behind docs/macos-spaces-api-research.html
//
// Standalone probe for the private macOS Spaces APIs. Not part of the app target
// (project.yml only globs AnyDrag/Sources), so this never ships.
//
//   swiftc -O docs/spaces-probe.swift -o /tmp/spaces-probe \
//          -F /System/Library/PrivateFrameworks -framework SkyLight
//   /tmp/spaces-probe                # read-only: spaces, windows-per-space, symbol check
//   /tmp/spaces-probe --test-write   # ALSO launches a throwaway TextEdit and tries to
//                                    # move its window between Spaces, then quits it
//
// `import CoreGraphics` is required: CGS* symbols are exported by CoreGraphics,
// only the SLS* aliases live in SkyLight. Linking SkyLight alone fails to resolve them.

import Cocoa
import CoreGraphics

typealias CGSConnectionID = UInt32
typealias CGSSpaceID = UInt64

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID
@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ cid: CGSConnectionID) -> CFArray
@_silgen_name("CGSManagedDisplayGetCurrentSpace")
func CGSManagedDisplayGetCurrentSpace(_ cid: CGSConnectionID, _ displayUuid: CFString) -> CGSSpaceID
@_silgen_name("CGSCopySpacesForWindows")
func CGSCopySpacesForWindows(_ cid: CGSConnectionID, _ mask: Int, _ wids: CFArray) -> CFArray
@_silgen_name("CGSCopyWindowsWithOptionsAndTags")
func CGSCopyWindowsWithOptionsAndTags(_ cid: CGSConnectionID, _ owner: Int, _ spaces: CFArray,
                                      _ options: Int, _ setTags: UnsafeMutablePointer<Int>,
                                      _ clearTags: UnsafeMutablePointer<Int>) -> CFArray
@_silgen_name("CGSSpaceGetType")
func CGSSpaceGetType(_ cid: CGSConnectionID, _ sid: CGSSpaceID) -> Int32
@_silgen_name("CGSSpaceCopyName")
func CGSSpaceCopyName(_ cid: CGSConnectionID, _ sid: CGSSpaceID) -> CFString?
@_silgen_name("CGSMoveWindowsToManagedSpace")
func CGSMoveWindowsToManagedSpace(_ cid: CGSConnectionID, _ windows: CFArray, _ space: CGSSpaceID)
@_silgen_name("CGSAddWindowsToSpaces")
func CGSAddWindowsToSpaces(_ cid: CGSConnectionID, _ windows: CFArray, _ spaces: CFArray)

let cid = CGSMainConnectionID()
let kAllSpacesMask = 0x7   // CGSSpaceIncludesUser | IncludesOthers | IncludesCurrent

func spacesOf(_ wid: Int) -> [CGSSpaceID] {
    (CGSCopySpacesForWindows(cid, kAllSpacesMask, [wid] as CFArray) as? [CGSSpaceID]) ?? []
}

struct WinInfo { let owner: String; let layer: Int; let onscreen: Bool }
func windowTable() -> [Int: WinInfo] {
    var t = [Int: WinInfo]()
    for i in (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []) {
        guard let n = i[kCGWindowNumber as String] as? Int else { continue }
        t[n] = WinInfo(owner: (i[kCGWindowOwnerName as String] as? String) ?? "?",
                       layer: (i[kCGWindowLayer as String] as? Int) ?? -999,
                       onscreen: (i[kCGWindowIsOnscreen as String] as? Bool) ?? false)
    }
    return t
}

func allSpaces() -> [CGSSpaceID] {
    var out = [CGSSpaceID]()
    for d in (CGSCopyManagedDisplaySpaces(cid) as? [NSDictionary] ?? []) {
        for s in (d["Spaces"] as? [NSDictionary] ?? []) {
            if let x = s["id64"] as? CGSSpaceID { out.append(x) }
        }
    }
    return out
}

// ── 1. what is on each Space ────────────────────────────────────────────────
print("connection = \(cid)")
let wins = windowTable()
print("public CGWindowListCopyWindowInfo sees \(wins.count) windows (it carries no Space info)\n")

for (di, disp) in (CGSCopyManagedDisplaySpaces(cid) as? [NSDictionary] ?? []).enumerated() {
    let uuid = disp["Display Identifier"] as? String ?? "?"
    let current = CGSManagedDisplayGetCurrentSpace(cid, uuid as CFString)
    print("Display #\(di) uuid=\(uuid) current=\(current)")
    for sp in (disp["Spaces"] as? [NSDictionary] ?? []) {
        guard let sid = sp["id64"] as? CGSSpaceID else { continue }
        // NOTE: CGSSpaceCopyName returns the Space UUID, not a human-readable name.
        // macOS does not store Space names at all.
        let name = CGSSpaceCopyName(cid, sid) as String? ?? ""
        var a = 0, b = 0
        // method A: per-Space. Fast, but misses minimised/hidden windows.
        let viaSpace = Set((CGSCopyWindowsWithOptionsAndTags(cid, 0, [sid] as CFArray, 0x2, &a, &b) as? [Int]) ?? [])
        print("  space id64=\(sid) type=\(CGSSpaceGetType(cid, sid)) uuid=\(name)\(sid == current ? "  <== current" : "")")
        print("    method A (per-Space):   \(viaSpace.count) windows")
    }
}

// method B: per-window. Complete — this is the one to build on.
// The batch form is a trap: passing N window ids returns a DE-DUPLICATED set of
// Space ids, not an array parallel to the input. Always query one window at a time.
var bySpace = [CGSSpaceID: [String]]()
var mapped = 0
for (wid, info) in wins {
    let s = spacesOf(wid)
    if !s.isEmpty { mapped += 1 }
    guard info.layer == 0 else { continue }   // filter out WindowServer/menu/IME layers
    for sid in s { bySpace[sid, default: []].append(info.owner + (info.onscreen ? "" : "(offscreen)")) }
}
print("\nmethod B (per-window): \(mapped)/\(wins.count) windows belong to a Space")
for (sid, apps) in bySpace.sorted(by: { $0.key < $1.key }) {
    print("  space \(sid): \(apps.sorted().joined(separator: ", "))")
}

// ── 2. do the write symbols exist? ──────────────────────────────────────────
print("\nsymbol check (existence only, nothing is called):")
let h = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
for n in ["CGSMoveWindowsToManagedSpace", "CGSAddWindowsToSpaces", "CGSRemoveWindowsFromSpaces",
          "CGSSpaceCreate", "CGSSpaceDestroy", "CGSManagedDisplaySetCurrentSpace",
          "CGSSetWindowListWorkspace", "CGSSpaceSetCompatID"] {
    let found = dlsym(h, n) ?? dlsym(UnsafeMutableRawPointer(bitPattern: -2), n)
    print("  \(n): \(found != nil ? "EXISTS" : "missing")")
}
print("  (…but see below: existing does not mean usable on foreign windows)")

// ── 3. optional: prove the write APIs no-op on another app's window ─────────
guard CommandLine.arguments.contains("--test-write") else {
    print("\nrun with --test-write to exercise the write path (launches + quits TextEdit)")
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
func settle(_ s: TimeInterval = 0.6) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

// Control: our OWN window moves fine.
print("\n[control] our own window")
let win = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 320, height: 120),
                   styleMask: [.titled], backing: .buffered, defer: false)
win.orderFront(nil); settle(0.4)
let mine = Int(win.windowNumber)
let mineHome = spacesOf(mine)
if let target = allSpaces().first(where: { !mineHome.contains($0) }) {
    CGSMoveWindowsToManagedSpace(cid, [mine] as CFArray, target); settle(0.4)
    print("  \(mineHome) -> \(target): now \(spacesOf(mine))  \(spacesOf(mine) == [target] ? "MOVED" : "NO-OP")")
}
win.orderOut(nil)

// Real case: a FOREIGN window.
print("\n[foreign] TextEdit")
let cfg = NSWorkspace.OpenConfiguration(); cfg.activates = false
let sem = DispatchSemaphore(value: 0)
var te: NSRunningApplication?
NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                   configuration: cfg) { a, _ in te = a; sem.signal() }
_ = sem.wait(timeout: .now() + 10); settle(2.5)
guard let pid = te?.processIdentifier else { print("  launch failed"); exit(1) }

func teWindow() -> Int? {
    (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []).first {
        ($0[kCGWindowOwnerPID as String] as? Int32) == pid
            && ($0[kCGWindowLayer as String] as? Int) == 0
            && (($0[kCGWindowBounds as String] as? [String: Any])?["Height"] as? Double ?? 0) > 100
    }?[kCGWindowNumber as String] as? Int
}
if teWindow() == nil {
    NSAppleScript(source: "tell application \"TextEdit\" to make new document")?.executeAndReturnError(nil)
    settle(2.0)
}
if let w = teWindow() {
    let home = spacesOf(w)
    if let target = allSpaces().first(where: { !home.contains($0) }) {
        CGSMoveWindowsToManagedSpace(cid, [w] as CFArray, target); settle()
        print("  CGSMoveWindowsToManagedSpace \(home) -> \(target): now \(spacesOf(w))")
        CGSAddWindowsToSpaces(cid, [w] as CFArray, [target] as CFArray); settle()
        print("  CGSAddWindowsToSpaces        \(home) -> \(target): now \(spacesOf(w))")
        print("  (both observed as NO-OP on macOS 26.4.1 — no error, no movement)")
    }
}
te?.terminate()
print("\nTextEdit terminated")
