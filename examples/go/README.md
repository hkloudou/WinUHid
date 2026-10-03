# Go 调用示例

用 Go 调用 `WinUHid.dll` 和 `WinUHidDevs.dll`，创建虚拟鼠标和虚拟键盘。
只用标准库，不需要 C 编译器（不用 cgo），DLL 在运行时加载。

## 目录

| 文件 | 内容 |
| --- | --- |
| `winuhid/winuhid.go` | 加载两个 DLL；`WinUHid.dll` 的通用接口：`CreateDevice`、`Start`、`SubmitInputReport`、`Close` |
| `winuhid/mouse.go` | `WinUHidDevs.dll` 里现成的鼠标：`NewMouse`、`Move`、`Button`、`Scroll` |
| `winuhid/keyboard.go` | 用通用接口做的键盘（`WinUHidDevs.dll` 没有现成键盘）：`NewKeyboard`、`KeyDown`、`KeyUp` |
| `main.go` | 演示程序：创建鼠标和键盘，操作一下，并检查输入是否真的到达系统 |

## 最小用法

```go
if err := winuhid.Load(`C:\path\to\lib`); err != nil { ... } // 放着两个 DLL 的目录

mouse, err := winuhid.NewMouse(0x1234, 0x5678) // 换成你自己的厂商号和产品号
if err != nil { ... }
defer mouse.Close()

time.Sleep(2 * time.Second) // 新设备要等系统准备好，太早发的输入会丢
mouse.Move(50, 0)
mouse.Button(winuhid.ButtonLeft, true)
mouse.Button(winuhid.ButtonLeft, false)

keyboard, err := winuhid.NewKeyboard(0x1234, 0x5679)
if err != nil { ... }
defer keyboard.Close()

keyboard.KeyDown(winuhid.KeyA)
keyboard.KeyUp(winuhid.KeyA)
```

## 运行演示程序

前提：已经用测试包的 `install.cmd` 装好驱动。用管理员身份打开命令行：

```
winuhid-sample.exe                      创建鼠标和键盘，移动指针，按一下左 Shift
winuhid-sample.exe -type "Hello 123"    另外：倒数 5 秒后用虚拟键盘打字（先点到记事本里）
winuhid-sample.exe -click               另外：在指针所在位置按一下鼠标左键
winuhid-sample.exe -dll-dir C:\path     指定两个 DLL 所在目录
```

测试包里的 `winuhid-sample.exe` 是流水线编译好的，默认到 `..\..\lib` 找 DLL。

自己编译，进入 `examples/go` 目录后：

```
go build -o winuhid-sample.exe .                              在 Windows 上
GOOS=windows GOARCH=amd64 go build -o winuhid-sample.exe .    在 Mac 或 Linux 上交叉编译
```

## 要注意的地方

- **必须以管理员或 SYSTEM 身份运行。** 驱动只允许这两类身份创建虚拟设备，否则返回 `winuhid.ErrAccessDenied`。
- **新设备创建后要等一下。** Windows 准备好设备之前发的输入会丢。演示程序的做法是反复试、直到看到指针动了。
- **厂商号和产品号要用自己的。** 示例里的 `0x1234` 只是占位。厂商号传 0 会被拒绝，因为那样库会冒用微软鼠标的编号。
- **`-type` 按的是键位，不是字符。** 打出什么取决于目标窗口当前的键盘布局和输入法；开着中文输入法时字母会进输入法。
- **远程桌面会话里看不到效果。** 虚拟设备的输入进的是本机屏幕那个会话。
- **设备随进程存在。** 调 `Close` 或进程退出，设备就从系统里消失。
- `Keyboard` 一次最多同时按住 6 个普通键外加修饰键，不能多个 goroutine 同时用。
