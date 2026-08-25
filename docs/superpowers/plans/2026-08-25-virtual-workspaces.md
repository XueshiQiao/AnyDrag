# AnyDrag 虚拟工作区 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给 AnyDrag 加虚拟工作区——把窗口分成几组、一次只显示一组，入口是现有的中键 Bento 面板：一次拖拽同时决定「丢到哪个工作区」和「到了那儿摆在哪」。

**Architecture:** 隐藏窗口的手段是把它用 Accessibility 挪到显示器可见区域外的角落（和 AeroSpace 同一招，已读过其源码确认），恢复时挪回完整的原始 frame。核心是一张**事件驱动的窗口登记表**，它同时是工作区归属的真相来源和面板绘制的数据缓存——面板弹出时只读内存，永不枚举。面板从「一张卡 = 一台显示器」扩展成「一张卡 = 一个工作区」，列 = 显示器、行 = 工作区。

**Tech Stack:** Swift 5.9 / AppKit / Accessibility API (`AXUIElement`, `AXObserver`) / CoreGraphics (`CGWindowList`, `CGDisplayCreateUUIDFromDisplayID`) / XcodeGen / UserDefaults + JSON 落盘

**Spec:** `docs/workspace-bento-mockups.html`（交互与视觉稿）+ `~/dotfiles/notes/aerospace-虚拟工作区调研.html`（机制调研，含 AeroSpace 源码依据）

---

## 优先级：先回答「手感对不对」，其余全部靠后

**2026-08-25 修订。** 初版计划把工程风险（会不会弄丢窗口）全部前置，把面板排到第三个里程碑。用户指出这是错的，我认同——理由如下，这一段是本计划最重要的判断：

这个功能有两种风险：**产品风险**（这东西好不好用、手感对不对）和**工程风险**（会不会把窗口弄丢）。**产品风险是主导的**：手感不对，整个需求会被推掉，前面所有工程投入白费。

而「用菜单栏切工作区」根本回答不了手感问题——这个功能的本体是那个中键手势，不是菜单。初版把菜单栏切换当作第一个里程碑的验收标准，是自欺欺人。

工程风险的后果也没有初版写的那么重：藏起来的窗口在角落会露出 1 个像素，**崩溃后用户可以手动把那 1px 拖回来**（AeroSpace 文档明确提到这一点）。最坏情况是麻烦，不是丢数据。

所以顺序改成：**先用最少的地基撑起完整的面板，拿去真用几天，手感不行就到此为止。**

### 唯一不能在原型阶段放松的约束

**面板弹出时只读内存，绝不枚举窗口。** 面板弹出在中键按下的热路径上，卡一下手感就毁了——而手感恰恰是原型要回答的唯一问题。原型阶段如果允许弹出时现枚举，**测出来的手感是假的**。

但「内存怎么保持新鲜」这一层可以粗暴：原型只在**切换工作区时**和**app 激活时**枚举刷新，不做 AXObserver 那一整套增量更新。只要 `entries(in:)` 的接口是读内存，以后把刷新机制换成 AXObserver 就是替换实现，不是重写。

### 里程碑

| | 目标 | 内容 | 任务 |
|---|---|---|---|
| **P1** | **回答「手感对不对」** | 隐藏/恢复 + 粗暴刷新的登记表 + 完整面板（卡片布局、总览层、三态、投放、跳转、纯切换）+ 逃生口。开关走 `defaults write`，**不做设置页** | T1–T5、T9–T13 |
| — | **停下来真用几天** | **手感不行就到此为止，P2 之后全部不做** | — |
| **P2** | 敢日常用 | Cmd+Tab / Dock / 通知 焦点跟随、退出兜底 | T6、T8 |
| **P3** | 能给别人用 | 设置页 + 本地化、显示器拔插、投放反馈、三档当前态、命中区加宽 | T7、T14–T17 |
| **P4** | 打磨 | 补测试工程、数字键加速、AeroSpace 冲突提示 | T0、T18–T19 |

**关于显示器拔插（T7）**：它排在 P3，但**必须在开始日常使用之前做完**——本项目的用户是天天合盖的笔记本用户。它的位置取决于你什么时候开始真用，不取决于什么时候上线。

**关于测试工程（T0）**：初版把它排在最前面，现在挪到 P4。原型阶段反馈已经够快（窗口飞没飞 5 秒就知道），而且还没有任何东西需要防止再次出现——测试是给稳定下来的代码用的。

### 原型阶段的逃生口（跟着 T3 一起做，不单独立里程碑）

菜单栏「把所有窗口放回来」+ 启动时扫一遍恢复，加起来约 30 行。**理由不是保护用户，是保护开发效率**：原型阶段拿真实窗口测，debug 版会崩，每崩一次要去角落抠 1px 把窗口拖回来。当天就回本。

## Global Constraints

这一节的每一条，**都隐含地属于下面每一个任务的验收条件**。

- **绝不在拖拽热路径上枚举窗口或取图标。** 中键按下到面板出现之间，只允许读内存里的 `WindowRegistry`。任何 `CGWindowListCopyWindowInfo` / `AXUIElementCopyAttributeValue` / `NSRunningApplication.icon` 调用都必须发生在后台的事件回调里，不在这条路径上。
- **绝不做逐帧的 Accessibility 拖拽。** 隐藏/恢复是一次性的 `setPosition`。参见项目既有约束：AX 延迟正是 AnyDrag 存在的理由。
- **日志一律走 `FileLog`**，禁止 `NSLog` / `print`。写入 `~/Library/Logs/AnyDrag/AnyDrag.log`。
- **落盘标识用 UUID，不用会变的整数 id。** 显示器用 `CGDisplayCreateUUIDFromDisplayID` 得到的 UUID 字符串；`CGDirectDisplayID` 和 `CGWindowID` 都不跨重启稳定。
- **配置向后兼容**：读取时忽略不认识的字段并原样保留，缺字段走默认值。
- **切换工作区不做动画**（用户已定：硬切）。窗口位置直接生效，不插值、不淡入淡出。
- **新增用户可见文案必须同时进 `en.lproj` 和 `zh-Hans.lproj` 的 `Localizable.strings`。**
- **Swift 类型检查预算**：避免长串 `1<<X | 1<<Y | …` 位或链，用带类型标注的数组 + `reduce`。本仓库有过 GH Actions 上 "unable to type-check in reasonable time" 的先例。

> **关于下面的编号**：– 是初版的分组名，任务编号（T0–T20）保持不变。**实际执行顺序以上面的 P1–P4 表为准**，不要按 M 的顺序做。

---

## 文件结构

新增一个目录 `AnyDrag/Sources/Workspaces/`，六个文件，各管一件事：

| 文件 | 唯一职责 |
|---|---|
| `Workspace.swift` | 纯数据：`Workspace`、`WorkspaceID`、`DisplayKey`。无副作用，可单测。 |
| `WindowRegistry.swift` | 活的窗口登记表。事件驱动增量更新。**唯一知道「哪个窗口属于哪个工作区」的地方。** |
| `WindowHider.swift` | 只管两件事：把这个窗口挪到角落、把它挪回去。不知道工作区是什么。 |
| `WorkspaceStore.swift` | 落盘与读回。崩溃后的恢复扫描。 |
| `WorkspaceController.swift` | 编排层：切换工作区、显示器拔插、焦点跟随。上面四个都归它调。 |
| `WorkspaceGeometry.swift` | 纯函数：卡片布局算数（列 = 显示器、行 = 工作区）、命中判定。可单测。 |

改动既有文件：

| 文件 | 改什么 |
|---|---|
| `Preferences.swift` | 新增 6 个键 + 默认值 + 迁移 |
| `MenuBarController.swift` | 当前工作区显示、切换菜单、「把所有窗口放回来」 |
| `TileCancelDot.swift` | 卡片从「每显示器一张」扩展到「每工作区一张」；总览层；跳转框 |
| `TileZone.swift` | 新增 `.jump`；命中判定接受工作区卡 |
| `DragEngine.swift` | 中键按在桌面空白处的分支；投放提交走 `WorkspaceController` |
| `Settings/PreferencesWindowController.swift` | 侧栏加一项 |
| `Settings/WorkspacePage.swift` | 新建，设置页 |
| `Resources/*.lproj/Localizable.strings` | 新文案 |
| `project.yml` | 新增测试 target |

---

# M0 · 测试地基

### Task 0: 加一个测试 target，只测纯逻辑

AnyDrag 现在没有测试 target。这个功能里有三块**纯计算**——工作区编号换算、隐藏点坐标、面板卡片布局——它们不碰系统状态，正是单测最划算的地方，也是最容易出符号错误（Y 轴方向、off-by-one）的地方。UI 和 Accessibility 的部分照旧靠跑真机验证。

**Files:**
- Modify: `project.yml`
- Create: `AnyDragTests/WorkspaceGeometryTests.swift`

**Interfaces:**
- Consumes: 无
- Produces: 一个可跑的 `xcodebuild test` 命令，后续任务往里加用例

- [ ] **Step 1: 在 `project.yml` 里加测试 target**

```yaml
  AnyDragTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - AnyDragTests
    dependencies:
      - target: AnyDrag
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: me.xueshi.anydrag.tests
        GENERATE_INFOPLIST_FILE: YES
        MACOSX_DEPLOYMENT_TARGET: "13.0"
        SWIFT_VERSION: "5.9"
```

同时在 `schemes.AnyDrag` 下加：

```yaml
    test:
      targets:
        - AnyDragTests
```

- [ ] **Step 2: 写一个必然失败的占位测试，确认工程真的跑起来了**

```swift
// AnyDragTests/WorkspaceGeometryTests.swift
import XCTest
@testable import AnyDrag

final class WorkspaceGeometryTests: XCTestCase {
    func testHarnessIsWired() {
        XCTFail("占位：确认测试 target 真的被执行了")
    }
}
```

- [ ] **Step 3: 跑，确认它失败（而不是"没有测试被执行"）**

```bash
xcodegen generate
xcodebuild test -project AnyDrag.xcodeproj -scheme AnyDrag \
  -destination 'platform=macOS' 2>&1 | tail -20
```
期望：`testHarnessIsWired` FAILED，`Executed 1 test`。如果显示 `Executed 0 tests`，说明 target 没接上，回 Step 1。

- [ ] **Step 4: 删掉占位，换成一个真的会通过的**

```swift
    func testHarnessIsWired() {
        XCTAssertEqual(1 + 1, 2)
    }
```

- [ ] **Step 5: 跑，确认通过**

```bash
xcodebuild test -project AnyDrag.xcodeproj -scheme AnyDrag \
  -destination 'platform=macOS' 2>&1 | tail -5
```
期望：`** TEST SUCCEEDED **`

- [ ] **Step 6: 提交**

```bash
git add project.yml AnyDragTests/
git commit -m "test: add unit test target for workspace pure logic"
```

---

# M1 · 模型 + 隐藏/恢复 + 逃生口

做完这一段，**功能上已经通了**：能用菜单栏在工作区之间切，窗口正确藏起来和回来，`kill -9` 之后重启能把窗口找回来。还没有面板。

### Task 1: 工作区模型（纯数据）

**Files:**
- Create: `AnyDrag/Sources/Workspaces/Workspace.swift`
- Test: `AnyDragTests/WorkspaceModelTests.swift`

**Interfaces:**
- Consumes: 无
- Produces:
  - `struct DisplayKey: Hashable, Codable { let uuid: String }`
  - `static func DisplayKey.from(_ screen: NSScreen) -> DisplayKey?`
  - `struct WorkspaceID: Hashable, Codable { let display: DisplayKey; let index: Int }`
  - `struct Workspace { let id: WorkspaceID; var name: String }`
  - `func Workspace.defaultName(index: Int) -> String`

- [ ] **Step 1: 先写测试——显示器身份必须是跨重启稳定的 UUID**

```swift
// AnyDragTests/WorkspaceModelTests.swift
import XCTest
import AppKit
@testable import AnyDrag

final class WorkspaceModelTests: XCTestCase {

    func testDisplayKeyIsStableUUIDNotDisplayID() {
        guard let screen = NSScreen.main else { return XCTFail("没有主屏") }
        guard let k1 = DisplayKey.from(screen), let k2 = DisplayKey.from(screen) else {
            return XCTFail("DisplayKey.from 返回 nil")
        }
        XCTAssertEqual(k1, k2, "同一块屏必须得到同一个 key")
        // UUID 字符串形如 8-4-4-4-12，长度 36。CGDirectDisplayID 是个短数字，
        // 拿到短字符串说明用错了 API。
        XCTAssertEqual(k1.uuid.count, 36, "必须是 CGDisplayCreateUUIDFromDisplayID 的 UUID")
    }

    func testWorkspaceIDsAreDistinctPerIndexAndDisplay() {
        let a = DisplayKey(uuid: "AAAAAAAA-0000-0000-0000-000000000000")
        let b = DisplayKey(uuid: "BBBBBBBB-0000-0000-0000-000000000000")
        XCTAssertNotEqual(WorkspaceID(display: a, index: 0), WorkspaceID(display: a, index: 1))
        XCTAssertNotEqual(WorkspaceID(display: a, index: 0), WorkspaceID(display: b, index: 0))
        XCTAssertEqual(WorkspaceID(display: a, index: 0), WorkspaceID(display: a, index: 0))
    }

    func testDefaultNameIsOneBasedForHumans() {
        XCTAssertEqual(Workspace.defaultName(index: 0), "1")
        XCTAssertEqual(Workspace.defaultName(index: 1), "2")
    }
}
```

- [ ] **Step 2: 跑，确认编译失败（类型还不存在）**

```bash
xcodebuild test -project AnyDrag.xcodeproj -scheme AnyDrag -destination 'platform=macOS' 2>&1 | tail -20
```
期望：编译错误 `cannot find 'DisplayKey' in scope`

- [ ] **Step 3: 实现**

```swift
// AnyDrag/Sources/Workspaces/Workspace.swift
import AppKit

/// 一块显示器的稳定身份。
///
/// 用 UUID 而不是 `CGDirectDisplayID`：后者是会话内的临时编号，拔插一次、
/// 睡一觉醒来都可能变，落盘之后对不上。UUID 由固件序列号派生，跨重启稳定。
struct DisplayKey: Hashable, Codable {
    let uuid: String

    static func from(_ screen: NSScreen) -> DisplayKey? {
        guard let num = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        let displayID = CGDirectDisplayID(num.uint32Value)
        guard let cf = CGDisplayCreateUUIDFromDisplayID(displayID) else { return nil }
        let uuid = CFUUIDCreateString(nil, cf.takeRetainedValue()) as String
        return DisplayKey(uuid: uuid)
    }
}

/// 一个工作区的身份 = 哪块屏 + 第几个。
///
/// v1 里每块屏的工作区个数是同一个全局数字（见 issue #42）。`index` 从 0 开始，
/// 给人看的时候 +1。
struct WorkspaceID: Hashable, Codable {
    let display: DisplayKey
    let index: Int
}

struct Workspace {
    let id: WorkspaceID
    var name: String

    /// 用户没起名字时显示什么。人看的编号从 1 开始。
    static func defaultName(index: Int) -> String { String(index + 1) }
}
```

- [ ] **Step 4: 跑，确认通过**

```bash
xcodebuild test -project AnyDrag.xcodeproj -scheme AnyDrag -destination 'platform=macOS' 2>&1 | tail -5
```
期望：`** TEST SUCCEEDED **`

- [ ] **Step 5: 提交**

```bash
git add AnyDrag/Sources/Workspaces/Workspace.swift AnyDragTests/WorkspaceModelTests.swift
git commit -m "feat(workspaces): add Workspace / WorkspaceID / DisplayKey model"
```

---

### Task 2: 隐藏点的坐标算术（纯函数，先把符号钉死）

把「窗口该挪到哪个坐标」单独抽成纯函数再单测，因为这里最容易翻车：AX 用左上角原点、Y 向下，NSScreen 用左下角原点、Y 向上，符号搞反的结果是窗口飞到屏幕中间或者飞出所有显示器再也回不来。

**Files:**
- Create: `AnyDrag/Sources/Workspaces/WindowHider.swift`
- Test: `AnyDragTests/WindowHiderTests.swift`

**Interfaces:**
- Consumes: 无
- Produces:
  - `enum HideCorner: String, Codable { case bottomLeft, bottomRight }`
  - `static func WindowHider.hidePoint(windowSize:visibleFrameCG:corner:) -> CGPoint`
  - `static func WindowHider.hide(_ ax: AXUIElement, windowSize: CGSize, visibleFrameCG: CGRect, corner: HideCorner) -> CGPoint`
  - `static func WindowHider.restore(_ ax: AXUIElement, to frameCG: CGRect)`

- [ ] **Step 1: 写测试**

```swift
// AnyDragTests/WindowHiderTests.swift
import XCTest
@testable import AnyDrag

final class WindowHiderTests: XCTestCase {

    /// CG 坐标系：原点在主屏左上角，Y 向下。一块 1000×600 的可见区域，
    /// 左上角在 (0,0)，那么它的"底边"在 y = 600。
    let visible = CGRect(x: 0, y: 0, width: 1000, height: 600)

    func testBottomLeftPushesWindowFullyOffTheLeftEdge() {
        let size = CGSize(width: 400, height: 300)
        let p = WindowHider.hidePoint(windowSize: size, visibleFrameCG: visible, corner: .bottomLeft)
        // 窗口左上角要退到 -400 + 1，右边只剩 1pt 露在里面
        XCTAssertEqual(p.x, -399, accuracy: 0.01)
        // 顶边落在可见区底边上方 1pt，窗口整体在下面
        XCTAssertEqual(p.y, 599, accuracy: 0.01)
    }

    func testBottomRightPushesWindowFullyOffTheRightEdge() {
        let size = CGSize(width: 400, height: 300)
        let p = WindowHider.hidePoint(windowSize: size, visibleFrameCG: visible, corner: .bottomRight)
        XCTAssertEqual(p.x, 999, accuracy: 0.01)   // 左边只剩 1pt 露在里面
        XCTAssertEqual(p.y, 599, accuracy: 0.01)
    }

    /// 回归护栏：窗口再大，藏起来之后也不能有超过 2pt 留在可见区里。
    func testNoMoreThanTwoPointsRemainVisibleForAnySize() {
        for w in stride(from: 120.0, through: 2400.0, by: 137.0) {
            let size = CGSize(width: w, height: 300)
            for corner in [HideCorner.bottomLeft, .bottomRight] {
                let p = WindowHider.hidePoint(windowSize: size, visibleFrameCG: visible, corner: corner)
                let overlapX = corner == .bottomLeft
                    ? (p.x + w) - visible.minX      // 露在左边界右侧的宽度
                    : visible.maxX - p.x            // 露在右边界左侧的宽度
                XCTAssertLessThanOrEqual(overlapX, 2.0, "宽度 \\(w) / \\(corner) 露出太多")
                XCTAssertGreaterThan(overlapX, 0.0, "必须留一点，完全推出去 macOS 会拒绝")
            }
        }
    }

    /// 副屏的可见区不以 (0,0) 起头，偏移必须跟着走。
    func testRespectsNonZeroOriginOfSecondaryDisplay() {
        let secondary = CGRect(x: 2560, y: 0, width: 1000, height: 600)
        let p = WindowHider.hidePoint(windowSize: CGSize(width: 400, height: 300),
                                      visibleFrameCG: secondary, corner: .bottomRight)
        XCTAssertEqual(p.x, 3559, accuracy: 0.01)
    }
}
```

- [ ] **Step 2: 跑，确认编译失败**

期望：`cannot find 'WindowHider' in scope`

- [ ] **Step 3: 实现**

```swift
// AnyDrag/Sources/Workspaces/WindowHider.swift
import AppKit
import ApplicationServices

/// 窗口藏到哪个角。选一个在你的显示器排布里是空的角，否则会在隔壁屏上
/// 看见藏起来的窗口。
enum HideCorner: String, Codable, CaseIterable {
    case bottomLeft, bottomRight
}

/// 只负责两件事：把窗口挪到看不见的地方，把它挪回来。
/// 它不知道工作区是什么，也不记任何状态。
enum WindowHider {

    private static let log = FileLog("WindowHider")

    /// macOS 不允许把窗口完全推出屏幕——完全推出去这次调用会被静默拒绝，
    /// 窗口原地不动。所以必须留 1pt 在里面。
    private static let sliver: CGFloat = 1

    /// 纯算术，可单测。所有坐标都是 CG 坐标系（原点主屏左上，Y 向下），
    /// 返回的是窗口**左上角**该去的位置。
    static func hidePoint(windowSize: CGSize,
                          visibleFrameCG: CGRect,
                          corner: HideCorner) -> CGPoint {
        // 纵向两个角一样：顶边压在可见区底边上，整个窗口落到下面去。
        let y = visibleFrameCG.maxY - sliver
        switch corner {
        case .bottomLeft:
            // 往左推一整个窗口宽度，只留 sliver 在左边界内侧。
            return CGPoint(x: visibleFrameCG.minX - windowSize.width + sliver, y: y)
        case .bottomRight:
            // 左上角贴到右边界内侧 sliver 处，窗口其余部分在外面。
            return CGPoint(x: visibleFrameCG.maxX - sliver, y: y)
        }
    }

    /// 把窗口挪到角落。**只改位置，不碰尺寸**——尺寸留给 restore 用。
    /// 返回实际挪去的位置，调用方要把它落盘，崩溃后靠它认出"这窗口是我藏的"。
    @discardableResult
    static func hide(_ ax: AXUIElement,
                     windowSize: CGSize,
                     visibleFrameCG: CGRect,
                     corner: HideCorner) -> CGPoint {
        let p = hidePoint(windowSize: windowSize, visibleFrameCG: visibleFrameCG, corner: corner)
        setPosition(ax, p)
        return p
    }

    /// 挪回去。**位置和尺寸都要还原**——这一点和 AeroSpace 不同：它只还原
    /// 位置，因为切回来时平铺算法会重算尺寸；AnyDrag 背后没有那套算法，
    /// 用户拖成什么样就得还原成什么样。
    static func restore(_ ax: AXUIElement, to frameCG: CGRect) {
        // 先尺寸后位置：某些 app（Xcode、Terminal）会按自身约束夹住尺寸，
        // 先定位再改尺寸的话，夹完位置会漂。
        setSize(ax, frameCG.size)
        setPosition(ax, frameCG.origin)
    }

    private static func setPosition(_ ax: AXUIElement, _ p: CGPoint) {
        var mutable = p
        guard let v = AXValueCreate(.cgPoint, &mutable) else { return }
        AXUIElementSetAttributeValue(ax, kAXPositionAttribute as CFString, v)
    }

    private static func setSize(_ ax: AXUIElement, _ s: CGSize) {
        var mutable = s
        guard let v = AXValueCreate(.cgSize, &mutable) else { return }
        AXUIElementSetAttributeValue(ax, kAXSizeAttribute as CFString, v)
    }
}
```

- [ ] **Step 4: 跑，确认通过**

```bash
xcodebuild test -project AnyDrag.xcodeproj -scheme AnyDrag -destination 'platform=macOS' 2>&1 | tail -5
```
期望：`** TEST SUCCEEDED **`，4 个用例全过

- [ ] **Step 5: 提交**

```bash
git add AnyDrag/Sources/Workspaces/WindowHider.swift AnyDragTests/WindowHiderTests.swift
git commit -m "feat(workspaces): add WindowHider with unit-tested corner math"
```

---

### Task 3: 窗口登记表 —— 整个功能的心脏

**这是全计划风险最高的一个任务。** 它同时是三件事的唯一真相来源：谁属于哪个工作区、每个窗口该在什么位置、面板画图要用的数据。**它必须从第一天就是事件驱动的活缓存**——写成「用的时候现枚举」，M3 做面板时就得推倒重来（见 Global Constraints 第一条）。

**Files:**
- Create: `AnyDrag/Sources/Workspaces/WindowRegistry.swift`
- Test: `AnyDragTests/WindowRegistryTests.swift`

**Interfaces:**
- Consumes: `WorkspaceID`, `DisplayKey`（Task 1）
- Produces:
  - `struct WindowRef: Hashable { let windowID: CGWindowID; let pid: pid_t }`
  - `struct RegistryEntry { let ref: WindowRef; let bundleID: String; let appName: String; var workspace: WorkspaceID; var visibleFrameCG: CGRect; var isHidden: Bool; var hiddenAt: CGPoint?; var icon: NSImage? }`
  - `final class WindowRegistry` with:
    - `func entries(in ws: WorkspaceID) -> [RegistryEntry]`（**O(1) 查表，禁止枚举系统窗口**）
    - `func entry(for ref: WindowRef) -> RegistryEntry?`
    - `func assign(_ ref: WindowRef, to ws: WorkspaceID)`
    - `func markHidden(_ ref: WindowRef, at point: CGPoint)` / `func markVisible(_ ref: WindowRef, frame: CGRect)`
    - `func seedFromSystem(defaultWorkspaceFor: (NSScreen) -> WorkspaceID)`（**只在启动时调一次**）
    - `var onChange: (() -> Void)?`

- [ ] **Step 1: 写测试——查表必须是纯内存操作**

用一个可注入的假数据源，断言 `entries(in:)` 不触发任何系统调用。测试要覆盖：按工作区分组正确；`assign` 之后旧工作区不再包含它；`markHidden`/`markVisible` 状态互斥；**窗口被拖到另一台显示器时，归属自动改成那台屏当前可见的工作区**（这条规则容易被忘，忘了的话跨屏拖一次窗口就"属于"错的工作区了）。

```swift
func testWindowDraggedToAnotherDisplayJoinsThatDisplaysVisibleWorkspace() {
    let reg = WindowRegistry(iconProvider: { _ in nil })
    let mainWS = WorkspaceID(display: dispA, index: 0)
    let subWS  = WorkspaceID(display: dispB, index: 1)
    reg.upsert(ref: r1, bundleID: "com.apple.Safari", appName: "Safari",
               workspace: mainWS, frameCG: CGRect(x: 10, y: 10, width: 400, height: 300))
    // 模拟：窗口被拖到了 B 屏的地盘，而 B 屏当前显示的是 subWS
    reg.windowMoved(r1, toFrameCG: CGRect(x: 2600, y: 40, width: 400, height: 300),
                    visibleWorkspaceResolver: { _ in subWS })
    XCTAssertEqual(reg.entry(for: r1)?.workspace, subWS)
    XCTAssertTrue(reg.entries(in: mainWS).isEmpty)
    XCTAssertEqual(reg.entries(in: subWS).count, 1)
}
```

- [ ] **Step 2: 跑，确认失败**

- [ ] **Step 3: 实现登记表本体**

要点，逐条都要落实：
- 内部两张表：`[WindowRef: RegistryEntry]` 和 `[WorkspaceID: Set<WindowRef>]`。第二张是为了让 `entries(in:)` 是 O(1)，别每次遍历全量过滤。
- **图标预缩放**：拿到 `NSRunningApplication.icon` 后立刻缩到面板要的尺寸（13×13pt @2x）存进 entry，**不要存原图**——原图是 512×512，面板画 4 张卡 × 若干窗口时每帧缩放会掉帧。
- **只在启动时 `seedFromSystem` 一次**，用 `CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)`。之后全靠事件增量更新。
- 线程：登记表只在主线程读写。事件 tap 线程若要读，走一份 `OSAllocatedUnfairLock` 保护的只读快照（参照 `HyperCapslockCapsHoldSource` 里 `heldLock` 的写法）。

- [ ] **Step 4: 接事件源**

每个前台 app 建一个 `AXObserver`，订阅：`kAXWindowCreatedNotification`、`kAXUIElementDestroyedNotification`、`kAXWindowMovedNotification`、`kAXWindowResizedNotification`。app 的增减靠 `NSWorkspace.shared.notificationCenter` 的 `didLaunchApplicationNotification` / `didTerminateApplicationNotification`。

`LinkedWindowResizeController.swift:685-710` 已经有一份 `AXObserver` 的建立与回调写法，照着来，别另起炉灶。

**注意**：`kAXWindowMovedNotification` 在用户拖窗口时会高频触发。登记表更新 frame 要节流（合并 100ms 内的连续事件），否则会和 AnyDrag 自己的拖拽路径抢主线程。

- [ ] **Step 5: 跑测试 + 跑真机**

```bash
xcodebuild test -project AnyDrag.xcodeproj -scheme AnyDrag -destination 'platform=macOS' 2>&1 | tail -5
```
然后 build 并启动 app，在 `FileLog` 里确认：开新窗口 / 关窗口 / 拖到另一块屏，各自都有一条登记表更新日志，**并且拖窗口时日志不是每帧一条**（验证节流生效）。

- [ ] **Step 6: 提交**

```bash
git add AnyDrag/Sources/Workspaces/WindowRegistry.swift AnyDragTests/WindowRegistryTests.swift
git commit -m "feat(workspaces): add event-driven WindowRegistry as single source of truth"
```

---

### Task 4: 落盘与崩溃后恢复

窗口在屏幕外这件事只存在于内存里。`kill -9`、断电、崩溃，都会让窗口永远留在外面，**而且用户手上没有任何界面能把它们找回来**。这是本功能唯一的毁数据风险点。

**Files:**
- Create: `AnyDrag/Sources/Workspaces/WorkspaceStore.swift`
- Test: `AnyDragTests/WorkspaceStoreTests.swift`

**Interfaces:**
- Consumes: `WindowRef`, `RegistryEntry`（Task 3）、`HideCorner`（Task 2）
- Produces:
  - `struct HiddenWindowRecord: Codable { let bundleID: String; let windowTitle: String; let hiddenAt: CGPoint; let originalFrameCG: CGRect }`
  - `func WorkspaceStore.save(_ records: [HiddenWindowRecord])`
  - `func WorkspaceStore.loadPendingRestores() -> [HiddenWindowRecord]`
  - `func WorkspaceStore.clear()`
  - `func WorkspaceStore.matchOnLaunch(records:against:) -> [(AXUIElement, CGRect)]`（纯函数，可单测）

- [ ] **Step 1: 写测试——匹配逻辑必须容忍几个点的漂移，又不能误伤**

`CGWindowID` 跨重启不稳定，所以认窗口只能靠 **bundleID + 标题 + 当前位置离记录的藏匿点很近**。测试覆盖：位置差 3pt 内算命中；差 50pt 不算（用户自己把它拖回来了，别再动）；bundleID 不同不算；同一 app 两个窗口只有藏匿点匹配的那个被还原。

- [ ] **Step 2: 跑，确认失败**

- [ ] **Step 3: 实现**

要点：
- 落盘位置 `~/Library/Application Support/AnyDrag/hidden-windows.json`，**不放 UserDefaults**——UserDefaults 有写入延迟，崩溃时可能没落地。用 `Data.write(to:options:.atomic)`。
- **每次藏窗口后立刻写，不要攒批。** 这个文件很小，写入成本可以忽略，而攒批意味着崩溃时丢的正是最后那几个。
- 恢复扫描在 `applicationDidFinishLaunching` 里、**拿到辅助功能权限之后**跑一次。没权限就保留文件，下次再试。
- 恢复完成后 `clear()`。

- [ ] **Step 4: 跑测试**

- [ ] **Step 5: 真机验证崩溃场景**

这一步必须真做，不能推理：
```bash
# 1. 启动 app，藏几个窗口
# 2. 模拟崩溃（不是正常退出）
pkill -9 AnyDrag-Debug
# 3. 确认窗口确实还在屏幕外
# 4. 重新启动 app
# 5. 确认窗口自动回到了原来的位置和大小
```
在 `FileLog` 里确认有 `restored N windows on launch` 之类的记录。

- [ ] **Step 6: 提交**

```bash
git add AnyDrag/Sources/Workspaces/WorkspaceStore.swift AnyDragTests/WorkspaceStoreTests.swift
git commit -m "feat(workspaces): persist hidden windows and restore them after a crash"
```

---

### Task 5: 编排层 + 菜单栏入口（M1 的验收点）

**Files:**
- Create: `AnyDrag/Sources/Workspaces/WorkspaceController.swift`
- Modify: `AnyDrag/Sources/MenuBarController.swift`
- Modify: `AnyDrag/Sources/Preferences.swift`

**Interfaces:**
- Consumes: Task 1–4 全部
- Produces:
  - `final class WorkspaceController`
  - `func switchTo(_ ws: WorkspaceID)` —— 硬切，无动画
  - `func move(_ ref: WindowRef, to ws: WorkspaceID, zone: TileZone?)`
  - `func restoreAllWindows()` —— 逃生口
  - `var visibleWorkspace: [DisplayKey: WorkspaceID] { get }`
  - `var isEnabled: Bool`
- Preferences 新增键：`AnyDragWorkspacesEnabled`(Bool, 默认 false)、`AnyDragWorkspacesPerDisplay`(Int, 默认 2)、`AnyDragWorkspaceNames`([String: String])、`AnyDragWorkspaceHideCorner`(String, 默认 `bottomLeft`)、`AnyDragWorkspaceCardContent`(String, 默认 `layout`)、`AnyDragWorkspaceFocusFollow`(Bool, 默认 true)

- [ ] **Step 1: 实现 `switchTo`**

```swift
/// 硬切：藏走旧工作区的窗口，放回新工作区的窗口。不做动画（用户已定）。
func switchTo(_ ws: WorkspaceID) {
    guard isEnabled, let screen = screen(for: ws.display) else { return }
    let current = visibleWorkspace[ws.display]
    guard current != ws else { return }
    // 顺序很重要：先放回再藏走，中间会有一瞬两组窗口同时可见；
    // 先藏走再放回，中间会有一瞬桌面全空。后者观感更差，所以选前者。
    for e in registry.entries(in: ws) where e.isHidden { unhide(e) }
    if let current { for e in registry.entries(in: current) where !e.isHidden { hide(e, on: screen) } }
    visibleWorkspace[ws.display] = ws
    store.save(registry.allHiddenRecords())
    menuBar.refreshWorkspaceIndicator()
}
```

- [ ] **Step 2: 菜单栏加三样东西**

在 `MenuBarController` 的菜单里加一段（总开关关闭时整段隐藏，但**「把所有窗口放回来」始终显示**）：
1. 一行只读文字：`当前：主屏 · 编码`
2. 每个工作区一个可点的菜单项，点了就 `switchTo`
3. 分隔线 + **「把所有窗口放回来」**

状态栏图标的标题改为显示当前工作区名（参照 AeroSpace 的做法）。

- [ ] **Step 3: 加 Preferences 键与默认值**

照 `Preferences.swift` 现有写法：`Key` 里加常量、`apply(to engine:)` 里读出来赋值、缺失走默认。**总开关默认 false**——这是个改变窗口行为的功能，不能默认打开。

- [ ] **Step 4: 构建并启动真机**

```bash
xcodegen generate
xcodebuild -project AnyDrag.xcodeproj -scheme AnyDrag -configuration Debug build 2>&1 | tail -5
open ~/Library/Developer/Xcode/DerivedData/AnyDrag-*/Build/Products/Debug/AnyDrag-Debug.app
```

- [ ] **Step 5: 人工验收清单（M1 的门槛）**

先在设置里（或直接 `defaults write me.xueshi.anydrag.debug AnyDragWorkspacesEnabled -bool true`）打开开关，然后逐条确认：

| 要试的 | 该看到什么 |
|---|---|
| 菜单栏点「主屏 · 2」 | 当前屏的窗口瞬间消失，菜单栏标题变成 `2` |
| 再点「主屏 · 1」 | 窗口原样回来，**位置和大小都和走之前一模一样** |
| 在 2 里开一个新窗口，切回 1 再切回 2 | 新窗口留在 2 里，没跑到 1 去 |
| 点「把所有窗口放回来」 | 所有藏起来的窗口全部回到可见区域 |
| 藏几个窗口后 `pkill -9 AnyDrag-Debug`，再启动 | 窗口自动回来 |
| 关掉总开关 | 所有窗口自动放回 |

- [ ] **Step 6: 提交**

```bash
git add AnyDrag/Sources/Workspaces/WorkspaceController.swift AnyDrag/Sources/MenuBarController.swift AnyDrag/Sources/Preferences.swift
git commit -m "feat(workspaces): add WorkspaceController and menu bar switching"
```

---

# M2 · 敢日常用

M1 做完功能是通的，但**别急着日常使用**。下面两条不做，拔一次屏或按一次 Cmd+Tab 就会出事。

### Task 6: Cmd+Tab 焦点跟随

**问题**：用户按 Cmd+Tab 选中一个在隐藏工作区里的窗口，macOS 老老实实把它激活了——但它的坐标在屏幕外。用户看到的是「app 亮了、窗口没了」。同样的路径还有：点 Dock 图标、点通知、Spotlight 打开文件、`open` 命令。**这些全都要覆盖，不能只处理 Cmd+Tab。**

**Files:**
- Modify: `AnyDrag/Sources/Workspaces/WorkspaceController.swift`
- Test: `AnyDragTests/FocusFollowTests.swift`

**Interfaces:**
- Consumes: `WorkspaceController.switchTo`、`WindowRegistry.entry(for:)`
- Produces: `func WorkspaceController.handleFocusedWindowChanged(_ ref: WindowRef)`

- [ ] **Step 1: 写测试（纯决策逻辑）**

把「该不该跟随、跟到哪」抽成纯函数再测，别去测通知：

```swift
/// 返回 nil = 不用切；返回 ws = 切到这个工作区
static func targetWorkspace(forFocused ref: WindowRef,
                            entry: RegistryEntry?,
                            visible: [DisplayKey: WorkspaceID]) -> WorkspaceID?
```
用例：窗口可见 → nil（别乱切）；窗口隐藏且其工作区不可见 → 返回该工作区；窗口不在登记表里（比如系统对话框）→ nil；窗口隐藏但其工作区**已经**可见（不该出现的状态）→ nil 并打一条 warn 日志。

- [ ] **Step 2: 跑，确认失败**

- [ ] **Step 3: 实现并接上通知源**

订阅两个，缺一不可：
- `NSWorkspace.shared.notificationCenter` 的 `didActivateApplicationNotification` —— 覆盖点 Dock、Cmd+Tab 切 app
- 每个 app 的 `AXObserver` 上的 `kAXFocusedWindowChangedNotification` —— 覆盖同一个 app 内部换窗口

- [ ] **Step 4: 跑测试**

- [ ] **Step 5: 真机验收（必须真按）**

| 要试的 | 该看到什么 |
|---|---|
| 把 Safari 丢到工作区 2，切回 1，按 Cmd+Tab 选 Safari | **自动切到工作区 2**，Safari 窗口在眼前 |
| 同上，改成点 Dock 里的 Safari 图标 | 同样自动切过去 |
| 在工作区 1 里正常 Cmd+Tab 切两个可见窗口 | **不发生任何工作区切换**（别过度触发） |
| 点一条微信通知，而微信在隐藏工作区里 | 自动切过去 |

- [ ] **Step 6: 提交**

```bash
git add AnyDrag/Sources/Workspaces/WorkspaceController.swift AnyDragTests/FocusFollowTests.swift
git commit -m "feat(workspaces): follow focus into hidden workspaces (Cmd+Tab, Dock, notifications)"
```

---

### Task 7: 显示器拔插

**问题**：合盖出门，副屏那几个工作区里的窗口坐标属于一块不存在的屏。不处理 = 窗口永久消失。

**Files:**
- Modify: `AnyDrag/Sources/Workspaces/WorkspaceController.swift`
- Test: `AnyDragTests/DisplayChangeTests.swift`

**Interfaces:**
- Produces: `func WorkspaceController.handleScreenParametersChanged()`
- Produces（纯函数，可单测）: `static func migrationPlan(lost: [DisplayKey], remaining: [DisplayKey], perDisplay: Int) -> [WorkspaceID: WorkspaceID]`

- [ ] **Step 1: 写测试**

覆盖：副屏消失 → 它的 2 个工作区映射到主屏的对应编号；主屏消失（外接屏成为主屏）→ 同样能算出映射；**所有屏都消失**（合盖无外接）→ 返回空计划，且调用方必须什么都不做（不是把窗口挪到 0,0）。

- [ ] **Step 2: 跑，确认失败**

- [ ] **Step 3: 实现**

订阅 `NSApplication.didChangeScreenParametersNotification`。处理顺序**必须是**：

```
1. 先把所有藏在"即将消失的屏"上的窗口 unhide 到那块屏还在时的位置
   —— 趁它还在，坐标才有意义
2. 再算迁移计划，改登记表里的工作区归属
3. 再按新的可见工作区重新藏一遍
4. 立刻落盘
```

**顺序反了就会丢窗口**：先改归属再 unhide，就找不到原来该放哪儿了。

插回来时**不自动还原**——用户已经把窗口挪到别处了，再自动搬回去比不搬更吓人。只在日志里记一笔。

- [ ] **Step 4: 跑测试**

- [ ] **Step 5: 真机验收（要真拔线）**

| 要试的 | 该看到什么 |
|---|---|
| 副屏工作区里藏着窗口，拔掉副屏 | 窗口出现在主屏上，**没有消失** |
| 拔掉副屏后看菜单栏 | 只剩主屏的工作区，没有指向不存在显示器的条目 |
| 插回副屏 | 不发生自动搬迁；菜单栏重新出现副屏的工作区 |
| 合盖只剩内置屏，再打开 | 窗口都在，没有跑到屏幕外 |

- [ ] **Step 6: 提交**

```bash
git add AnyDrag/Sources/Workspaces/WorkspaceController.swift AnyDragTests/DisplayChangeTests.swift
git commit -m "feat(workspaces): migrate windows off displays that disappear"
```

---

### Task 8: 退出与崩溃兜底

**Files:**
- Modify: `AnyDrag/Sources/AppDelegate.swift`
- Modify: `AnyDrag/Sources/Workspaces/WorkspaceController.swift`

- [ ] **Step 1: 正常退出时放回所有窗口**

在 `applicationWillTerminate` 里调 `restoreAllWindows()`，然后 `store.clear()`。

- [ ] **Step 2: 关掉总开关时放回所有窗口**

`isEnabled` 的 `didSet` 里，从 true 变 false 就 `restoreAllWindows()`。设置页那个开关最终走的就是这条路。

- [ ] **Step 3: 加一层信号兜底**

给 `SIGTERM` / `SIGINT` 装 handler，尽最大努力放回。**注意**：signal handler 里能做的事极其有限，不能调 Objective-C runtime。所以这里只做一件事——把落盘文件的一个 `needsRestore` 标志置位（一次 `write(2)`），真正的恢复交给下次启动的扫描（Task 4 已经做好了）。`SIGKILL` 抓不到，那就是 Task 4 存在的理由。

- [ ] **Step 4: 真机验收**

| 要试的 | 该看到什么 |
|---|---|
| 藏几个窗口，从菜单栏正常退出 | 窗口立刻全部回来 |
| 藏几个窗口，设置里关掉总开关 | 窗口立刻全部回来 |
| 藏几个窗口，`pkill -9`，重启 app | 窗口回来（走 Task 4 的扫描） |

- [ ] **Step 5: 提交**

```bash
git add AnyDrag/Sources/AppDelegate.swift AnyDrag/Sources/Workspaces/WorkspaceController.swift
git commit -m "feat(workspaces): restore all windows on quit, on disable, and on next launch"
```

---

# M3 · 面板（正主）

设计依据：`docs/workspace-bento-mockups.html`。所有数值以该文档和 `TileCancelDot.swift` 现有常量为准。

### Task 9: 卡片布局算术

**Files:**
- Create: `AnyDrag/Sources/Workspaces/WorkspaceGeometry.swift`
- Test: `AnyDragTests/WorkspaceGeometryTests.swift`（Task 0 已建）

**Interfaces:**
- Produces: `static func WorkspaceGeometry.layout(screens: [NSScreen], perDisplay: Int, cardSize: CGSize, gap: CGFloat) -> (panelSize: CGSize, cards: [WorkspaceCard])`
- Produces: `struct WorkspaceCard { let ws: WorkspaceID; let rect: CGRect; let isCurrentDisplay: Bool; let isCurrentWorkspace: Bool }`

- [ ] **Step 1: 写测试**

覆盖：2 屏 × 2 工作区 → 4 张卡，2 列 2 行，总尺寸 `592 × 432`（290×2+12，210×2+12）；列的左右顺序跟随显示器的物理 x 顺序；**1 屏 × 2 工作区 → 一列两张卡**（不能沿用「必须 ≥2 屏」那条老限制，见设计稿第 5 节第 10 条）；perDisplay=1 时退化成和今天一样的一行。

- [ ] **Step 2: 跑，确认失败**

- [ ] **Step 3: 实现**

复用 `TileCancelDot.swift:690-730` 现有的「按 x 中心把屏分列」逻辑，在它外面套一层「每列纵向排 perDisplay 张卡」。卡片总高 = `cardTitleAreaHeight(25) + panelHeight(185) = 210`。

- [ ] **Step 4: 跑测试**

- [ ] **Step 5: 提交**

```bash
git add AnyDrag/Sources/Workspaces/WorkspaceGeometry.swift AnyDragTests/WorkspaceGeometryTests.swift
git commit -m "feat(workspaces): compute bento card layout for display x workspace grid"
```

---

### Task 10: 卡片总览层

**Files:**
- Modify: `AnyDrag/Sources/TileCancelDot.swift`

- [ ] **Step 1: 画窗口缩略**

每个窗口画成一个圆角矩形 + 顶部一条 9pt 的标题栏 + 左上角 6pt 的 app 图标。窗口 frame 从 `WindowRegistry.entries(in:)` 拿，按卡片网格内容区（266×161）等比映射。图标用 Task 3 预缩放好的那张，**不要现取**。

- [ ] **Step 2: 空工作区显示占位文字**

居中一行淡色「空」。

- [ ] **Step 3: 三态透明度**

按设计稿第 3 节那张表：不指着这张卡 → 总览 100% / 九宫格不画；光标在网格里 → 总览 25% / 九宫格 100%；光标在外层框 → 总览 100% / 九宫格收起。

- [ ] **Step 4: 用离屏渲染验证**

不要靠脑补。把面板渲染成图片自己看一眼：
```swift
// 临时调试代码：把 panel.contentView 渲染成 PNG 存到 /tmp 再打开看
```
参照项目既有做法（记忆条目「看不见就把 UI 抓下来」）。确认：图标看得清、窗口边界分得开、四张卡不糊成一片。

- [ ] **Step 5: 提交**

```bash
git add AnyDrag/Sources/TileCancelDot.swift
git commit -m "feat(workspaces): draw real window layout overview inside each card"
```

---

### Task 11: 三态命中判定 + 跳转框

**Files:**
- Modify: `AnyDrag/Sources/TileZone.swift`
- Modify: `AnyDrag/Sources/TileCancelDot.swift`
- Test: `AnyDragTests/WorkspaceGeometryTests.swift`

**Interfaces:**
- Produces: `enum WorkspaceHit { case tile(WorkspaceID, TileZone); case jump(WorkspaceID); case none }`
- Produces: `static func WorkspaceGeometry.hit(cursorCG: CGPoint, cards: [WorkspaceCard]) -> WorkspaceHit`

- [ ] **Step 1: 写测试——跳转框的判定区必须比画出来的宽**

设计稿第 5 节第 6 条：网格四周只有 12pt 内边距，底边 12pt 在快速拖拽时根本瞄不准。**判定区往里再吃 6pt、往外吃到卡片外 8pt**，视觉上还是那一圈。测试要断言：卡片外 6pt 处仍命中 `jump`；网格边缘往内 3pt 处仍命中 `jump` 而不是底排格子；网格正中命中 `tile`。

- [ ] **Step 2: 跑，确认失败**

- [ ] **Step 3: 实现**

判定顺序：先看在不在某张卡的「扩大后的外层框」里 → `jump`；否则看在不在网格里 → `tile`；都不是 → `none`（松手即取消）。

- [ ] **Step 4: 画跳转态**

命中 `jump` 时：整卡描 2pt 强调色内描边，标题行文字换成 `↳ 跳到「<名字>」` 并变成强调色，九宫格收起。（设计稿里跳转提示是**替换标题行**，不是浮在卡外的药丸——浮在外面会压住上一行的卡。）

- [ ] **Step 5: 跑测试 + 离屏渲染确认视觉**

- [ ] **Step 6: 提交**

```bash
git add AnyDrag/Sources/TileZone.swift AnyDrag/Sources/TileCancelDot.swift AnyDragTests/WorkspaceGeometryTests.swift
git commit -m "feat(workspaces): add jump frame hit testing with widened target area"
```

---

### Task 12: 投放与跳转的提交

**Files:**
- Modify: `AnyDrag/Sources/DragEngine.swift`

- [ ] **Step 1: 接上 `applyTile` 的工作区分支**

松手时按 `WorkspaceHit` 分派：
- `.tile(ws, zone)` —— 目标工作区可见 → 走今天的 `applyTile` 路径；不可见 → 先 `registry.assign` 改归属，再按 zone 算出目标 frame 存进登记表，然后立刻 `hide`。**用户留在原地。**
- `.jump(ws)` —— 只 `switchTo(ws)`，**手上拖的窗口一动不动**（用户已定的语义）。
- `.none` —— 取消。

- [ ] **Step 2: 落盘**

任何一次改变隐藏状态之后立刻 `store.save`。

- [ ] **Step 3: 真机验收**

| 要试的 | 该看到什么 |
|---|---|
| 中键拖窗口到「副屏 · 参考」的右中格松手 | 窗口消失（去了那个隐藏工作区），自己还留在原地 |
| 切到「副屏 · 参考」 | 那个窗口在右半屏，尺寸正确 |
| 中键拖窗口到某张卡的**外层框**松手 | 切到那个工作区，**刚才拖的窗口没动** |
| 拖到当前工作区自己的格子 | 和今天的平铺行为完全一致 |
| 松手在所有卡之外 | 什么都不发生 |

- [ ] **Step 4: 提交**

```bash
git add AnyDrag/Sources/DragEngine.swift
git commit -m "feat(workspaces): commit drop and jump gestures from the bento panel"
```

---

### Task 13: 中键按在桌面空白处 = 纯切换

**Files:**
- Modify: `AnyDrag/Sources/DragEngine.swift`
- Modify: `AnyDrag/Sources/TileCancelDot.swift`

- [ ] **Step 1: 判定「光标下没有窗口」**

用 `CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)` 找光标下最上层的窗口，**排除 Finder 的桌面窗口**（`kCGWindowLayer` 为负、或 owner 是 Finder 且标题为空）。这一次枚举发生在中键按下时——属于热路径，所以**只在没找到目标窗口时才做**，正常拖窗口的路径不受影响。

- [ ] **Step 2: 面板进纯切换态**

不画九宫格、不显示目标窗口药丸，改为顶部一行强调色徽章「切换工作区 · 手上没有窗口」。整张卡都是跳转目标。

- [ ] **Step 3: 真机验收**

| 要试的 | 该看到什么 |
|---|---|
| 中键按在桌面空白处 | 面板弹出，没有九宫格、没有窗口药丸，有模式徽章 |
| 移到某张卡上松手 | 切到那个工作区 |
| 中键按在一个窗口上 | 还是正常的投放面板，行为不变 |
| 中键按在 Finder 桌面图标上 | 按「桌面空白」处理（不是把桌面当窗口拖） |

- [ ] **Step 4: 提交**

```bash
git add AnyDrag/Sources/DragEngine.swift AnyDrag/Sources/TileCancelDot.swift
git commit -m "feat(workspaces): middle-press on empty desktop opens the switcher"
```

---

### Task 14: 投放后的反馈

**问题**（设计稿第 5 节第 4 条）：把窗口丢进隐藏工作区，它就这么消失了，没有任何提示。第一次用的人会以为窗口被关掉了。

**Files:**
- Modify: `AnyDrag/Sources/TileCancelDot.swift`

- [ ] **Step 1: 松手后面板多留 350ms**

不要立刻消失。在这 350ms 里：目标卡片对应的位置上把这个 app 的图标画进去，并做一次强调色的闪烁（120ms 亮起、230ms 淡出）。面板本来就在屏幕上，这个反馈是免费的。

- [ ] **Step 2: 离屏渲染确认**

- [ ] **Step 3: 真机验收**：丢一个窗口过去，确认**看得见它去了哪儿**。

- [ ] **Step 4: 提交**

```bash
git add AnyDrag/Sources/TileCancelDot.swift
git commit -m "feat(workspaces): flash the destination card so the window doesn't just vanish"
```

---

### Task 15: 三档当前态标记

**问题**（设计稿第 5 节第 5 条）：今天「当前」只有一个意思——光标所在的显示器。加了工作区之后是一对（显示器, 工作区），需要三档而不是两档。

**Files:**
- Modify: `AnyDrag/Sources/TileCancelDot.swift`

- [ ] **Step 1: 实现三档**

| 档 | 画法 |
|---|---|
| 当前工作区 | 实心强调色圆点 + 强调色名字，内容 100% |
| 同一块屏的另一个工作区 | **空心**圆点 + 常规色名字，内容 100% |
| 别的屏的工作区 | 实心灰点 + 常规色名字，内容压到 82%（`dimmedContentAlpha`） |

列头也要标出当前在哪一列（强调色）。

- [ ] **Step 2: 离屏渲染确认三档真的分得出来**

- [ ] **Step 3: 提交**

```bash
git add AnyDrag/Sources/TileCancelDot.swift
git commit -m "feat(workspaces): three-level current-state marking on cards"
```

---

# M4 · 设置页

### Task 16: 「虚拟工作区」设置页

**Files:**
- Create: `AnyDrag/Sources/Settings/WorkspacePage.swift`
- Modify: `AnyDrag/Sources/Settings/PreferencesWindowController.swift`

**Interfaces:**
- Consumes: `WorkspaceController`、Task 5 里加的 6 个 Preferences 键
- Produces: `struct WorkspacePage: View`

- [ ] **Step 1: 侧栏加一项**

排在「中键」后面——这个功能挂在中键手势上，紧挨着它最好找。图标用 SF Symbol `rectangle.3.group`。

- [ ] **Step 2: 按设计稿实现七行**

顺序和文案照 `docs/workspace-bento-mockups.html` 第 4 节那张图：

| 行 | 控件 | 绑定的键 |
|---|---|---|
| 虚拟工作区（总开关） | Toggle | `AnyDragWorkspacesEnabled` |
| 每台显示器几个工作区 | 分段 1/2/3/4 | `AnyDragWorkspacesPerDisplay` |
| 工作区名字 | 每个工作区一个文本框 | `AnyDragWorkspaceNames` |
| 卡片里显示 | 分段 真实布局/仅数量/不显示 | `AnyDragWorkspaceCardContent` |
| 焦点跟随 | Toggle（默认开） | `AnyDragWorkspaceFocusFollow` |
| 窗口藏在哪个角 | 分段 左下/右下 | `AnyDragWorkspaceHideCorner` |
| 把所有窗口放回来 | 按钮 | 调 `restoreAllWindows()` |

**总开关关闭时下面全部 `.disabled(true)` 但不隐藏**——让人看得见「这儿有个功能没开」。「把所有窗口放回来」是例外，任何时候都可点。

- [ ] **Step 3: 减少工作区数量时要迁移窗口**

把 perDisplay 从 3 改成 2，第 3 个工作区里的窗口**必须迁移到第 2 个**，不能就这么留在屏幕外。复用 Task 7 的迁移逻辑。

- [ ] **Step 4: 构建 + 启动 + 截图设置页**

用项目里的 `appshot` skill 抓一张设置页截图自己看，确认排版没崩、开关联动正确。

- [ ] **Step 5: 真机验收**

| 要试的 | 该看到什么 |
|---|---|
| 关掉总开关 | 下面全变灰；藏起来的窗口立刻全部回来；中键面板退回按显示器分卡 |
| 打开总开关 | 面板变成工作区卡片 |
| 数量从 2 改成 1 | 第 2 个工作区的窗口迁移到第 1 个，一个都不少 |
| 改名字 | 面板卡片标题和菜单栏立刻跟着变 |
| 改藏匿角 | 下一次隐藏用新角落 |

- [ ] **Step 6: 提交**

```bash
git add AnyDrag/Sources/Settings/WorkspacePage.swift AnyDrag/Sources/Settings/PreferencesWindowController.swift
git commit -m "feat(workspaces): add Virtual Workspaces settings page"
```

---

### Task 17: 本地化

**Files:**
- Modify: `AnyDrag/Resources/en.lproj/Localizable.strings`
- Modify: `AnyDrag/Resources/zh-Hans.lproj/Localizable.strings`

- [ ] **Step 1: 把所有新文案两种语言都补上**

包括：设置页七行的标题与副标题、菜单栏条目、模式徽章、跳转提示、空工作区占位文字、默认工作区名。

- [ ] **Step 2: 检查没有漏网的硬编码字符串**

```bash
grep -rn '"[^"]*[一-龥][^"]*"' AnyDrag/Sources/Workspaces AnyDrag/Sources/Settings/WorkspacePage.swift | grep -v '^.*//' | grep -v NSLocalizedString
```
期望：无输出（除注释外没有裸中文串）。

- [ ] **Step 3: 两种语言各启动一次**

```bash
defaults write me.xueshi.anydrag.debug AnyDragLanguageOverride -string en
# 启动，翻一遍设置页和菜单栏
defaults write me.xueshi.anydrag.debug AnyDragLanguageOverride -string zh-Hans
```
确认没有出现 key 本身（说明没找到翻译）。

- [ ] **Step 4: 提交**

```bash
git add AnyDrag/Resources/*/Localizable.strings
git commit -m "i18n: localize Virtual Workspaces strings (en + zh-Hans)"
```

---

# M5 · 打磨

### Task 18: 面板弹出时按数字键直接选

面板已经在屏幕上了，此时按 `1`/`2` 直接命中对应工作区，几乎是白送的加速器——**不需要做完整的全局快捷键系统**。

**Files:**
- Modify: `AnyDrag/Sources/TileCancelDot.swift`

- [ ] **Step 1: 加一个只在面板可见期间存在的 key monitor**

`TilingPanel.swift:84` 已经有一份 `NSEvent.addGlobalMonitorForEvents(matching: .keyDown)` 的写法，照着来。面板消失时务必移除。

- [ ] **Step 2: 映射**

`1`…`N` → 当前显示器的第 N 个工作区，行为等同于「跳转」（切过去，窗口不动）。按住 Shift + 数字 → 等同于「原样投放」（窗口送过去，自己不动）。

- [ ] **Step 3: 真机验收**：面板弹出，按 `2`，切到工作区 2；按 Shift+2，窗口送到 2 且自己留下。

- [ ] **Step 4: 提交**

```bash
git add AnyDrag/Sources/TileCancelDot.swift
git commit -m "feat(workspaces): number-key accelerators while the panel is up"
```

---

### Task 19: 和 AeroSpace 同时运行的冲突提示

用户机器上装着 AeroSpace，两者都靠「把窗口挪到屏幕外」实现工作区。同时开会互相藏对方的窗口，结果不可预测。**别静默打架。**

**Files:**
- Modify: `AnyDrag/Sources/Settings/WorkspacePage.swift`

- [ ] **Step 1: 检测**

```swift
NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "bobko.aerospace" }
```
bundle id 已核实：`mdls -name kMDItemCFBundleIdentifier -r /Applications/AeroSpace.app` 返回 `bobko.aerospace`（AeroSpace 0.21.3-Beta）。

- [ ] **Step 2: 设置页顶部显示一条黄色提示**

文案要说清后果：「检测到 AeroSpace 正在运行。它和 AnyDrag 的虚拟工作区用的是同一种办法隐藏窗口，同时开启会互相干扰。建议只用其中一个。」不阻止用户，只提示。

- [ ] **Step 3: 真机验收**：启动 AeroSpace，打开设置页，确认提示出现；退出 AeroSpace，提示消失。

- [ ] **Step 4: 提交**

```bash
git add AnyDrag/Sources/Settings/WorkspacePage.swift
git commit -m "feat(workspaces): warn when AeroSpace is running alongside"
```

---

### Task 20: 收尾 —— 独立 review 与真机全流程

- [ ] **Step 1: 跑一遍全部单测**

```bash
xcodebuild test -project AnyDrag.xcodeproj -scheme AnyDrag -destination 'platform=macOS' 2>&1 | tail -10
```
期望：`** TEST SUCCEEDED **`

- [ ] **Step 2: 找 Coco 做独立 review**

按项目规矩（HARD RULE 4），实现类任务收尾前必须拿一次 Codex 的独立 review。后台跑，不阻塞。重点让她看：登记表的线程安全、显示器拔插的顺序、崩溃恢复的匹配逻辑会不会误伤用户自己拖回来的窗口。

- [ ] **Step 3: 全流程真机验收**

把 M1–M4 每个任务的验收表**从头到尾再跑一遍**——单个任务通过不代表合在一起还通过，尤其是拔屏 + 崩溃 + 关开关这几条互相有交叉。

- [ ] **Step 4: 性能回归**

这是本功能最容易悄悄退化的地方。开着工作区功能，用中键拖窗口，确认**面板弹出没有可感知的延迟**。如果 `FileLog` 里出现任何在中键按下路径上的窗口枚举或图标读取，就是 Global Constraints 第一条被违反了，必须改。

- [ ] **Step 5: 更新文档**

把设计稿 `docs/workspace-bento-mockups.html` 第 6 节「这份稿子里没有答案的」更新掉——硬切已定、每屏不同数量转 #42、工作区间搬窗口转 #41。

---

## 自查

**1. 设计稿覆盖检查** —— 设计稿第 5 节 13 条遗漏，逐条对应：

| 遗漏 # | 对应任务 |
|---|---|
| 1 Cmd+Tab 焦点跟随 | Task 6 |
| 2 显示器拔掉 | Task 7 |
| 3 面板性能 | Task 3 + Global Constraints + Task 20 Step 4 |
| 4 投放无反馈 | Task 14 |
| 5「当前」是两个维度 | Task 15 |
| 6 跳转框底边太窄 | Task 11 |
| 7 原生全屏 app | **缺** → 见下 |
| 8 最小化的窗口 | **缺** → 见下 |
| 9 新窗口落在哪 | Task 3（新窗口进当前工作区） |
| 10 单显示器 | Task 9 测试用例 |
| 11 和 AeroSpace 冲突 | Task 19 |
| 12 面板会不会太大 | 推迟，v1 上限 4 张卡不会爆 |
| 13 数字键加速 | Task 18 |

第 7、8 条在上面没有独立任务，补进 Task 3：

> **补充到 Task 3 的实现要点：**
> - **原生全屏的窗口不进登记表。** 判据：窗口 frame 等于所在屏的 `frame`（不是 `visibleFrame`）且 `AXFullScreen` 为真。它自己占一个 macOS Space，硬去挪只会打架。
> - **最小化的窗口保留登记但不参与隐藏/恢复。** 最小化是用户自己的动作，工作区不该覆盖它。从 Dock 点回来时走 Task 6 的焦点跟随自动切过去。

**2. 占位扫描** —— 全文无 TBD / TODO / 「稍后补充」/「类似 Task N」。每个 Step 都写了具体做什么、跑什么命令、期望看到什么。

**3. 类型一致性** —— `WorkspaceID` / `DisplayKey` / `WindowRef` / `RegistryEntry` / `HideCorner` / `WorkspaceHit` / `WorkspaceCard` 在定义处（Task 1、2、3、9、11）和使用处（Task 5、6、7、12）签名一致。`visibleFrameCG` 全文统一表示 CG 坐标系（原点主屏左上、Y 向下），NSScreen 坐标一律显式写成 `...NS`。

---

## 风险登记

| 风险 | 触发条件 | 应对 |
|---|---|---|
| **登记表和系统真实状态漂移** | app 崩了、AX 通知丢了、某些 app 不发通知 | 加一个低频（30s）的对账扫描，发现不一致就以系统为准修正登记表并记日志。**这个扫描在后台，不在热路径。** |
| **某些 app 拒绝被挪到屏幕外** | 部分 app 会夹住自己的位置（AeroSpace 源码里对 Zoom 有专门的 workaround） | 挪完读回位置校验，没挪成功就放弃隐藏该窗口并记日志，**不要反复重试**（会打架） |
| **面板卡片太多导致渲染变慢** | 3 屏 × 4 工作区 = 12 张卡 | v1 上限是 4 屏 × 4 = 16 张。若 Task 20 Step 4 测出问题，就把「卡片里显示」默认值降级为「仅数量」 |
| **和 BetterMouse 之类的事件工具打架** | 已知 BetterMouse 会重贴修饰键标记（见项目记忆） | 中键路径已有先例，本功能不新增修饰键依赖，风险低 |
