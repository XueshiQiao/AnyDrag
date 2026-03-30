# AnyDrag

按住修饰键，拖动窗口任意位置即可移动窗口，无需拖拽标题栏。

![AnyDrag 演示](demo.png)
<!-- 替换 demo.png 为截图或视频 -->

## 安装

从 [Releases](https://github.com/XueshiQiao/AnyDrag/releases) 下载最新 `.dmg`，或从源码构建：

```bash
brew install xcodegen
xcodegen generate
open AnyDrag.xcodeproj
```

## 使用

1. 启动 AnyDrag — 它会出现在菜单栏
2. 按住 **Option**（默认）拖动任意窗口
3. 点击菜单栏图标可以切换修饰键或开关

### 支持的修饰键

- Option
- Command
- Control
- fn
- Option + Command

## 要求

- macOS 13+
- 辅助功能权限（首次启动时会提示授权）

## 许可

MIT
