# Go 示例：不带任何 DLL

用 Go 直接和 WinUHid 驱动对话，创建虚拟键盘和虚拟鼠标。
不需要 `WinUHid.dll`、`WinUHidDevs.dll`，不需要 C 编译器，只用 Go 标准库。
目标机器上只要装了驱动（MSI）就能用，你的程序就是一个 exe。

只覆盖"只往系统送输入"的设备，键盘和鼠标都属于这一类。

## 目录

| 文件 | 内容 |
| --- | --- |
| `vhid/device.go` | 和驱动对话：打开 `\\.\WinUHid`，发设备信息、说明书、创建、启动，之后每份输入是一次写入 |
| `vhid/keyboard.go` | 键盘：`NewKeyboard`、`KeyDown`、`KeyUp`、`ReleaseAll` |
| `vhid/mouse.go` | 相对鼠标（按移动量走，游戏用）：`NewMouse`、`Move`、`Button`、`Scroll`、`ScrollHorizontal` |
| `vhid/absmouse.go` | 绝对定位鼠标（直接放到屏幕上某个位置，操作桌面用）：`NewAbsoluteMouse`、`MoveTo`、`MoveToPixel`、`Button`、`Scroll` |
| `main.go` | 演示程序：创建鼠标和键盘，操作一下，并检查输入是否真的到达系统 |
| `httpserver/` | 用网址操作键盘鼠标的参考程序 `winuhid-http.exe`。**只用于可行性验证和学习，不允许分发给用户**；边界和合规风险见该目录的 README.md |

`vhid` 这个包可以整个拷进你的工程用。

## 最小用法

```go
mouse, err := vhid.NewMouse(0x1234, 0x5688) // 换成你自己的厂商号和产品号
if err != nil { ... }
defer mouse.Close()

time.Sleep(2 * time.Second) // 新设备要等系统准备好，太早发的输入会丢
mouse.Move(50, 0)
mouse.Button(vhid.ButtonLeft, true)
mouse.Button(vhid.ButtonLeft, false)
mouse.Scroll(-1) // 滚轮向下一格

keyboard, err := vhid.NewKeyboard(0x1234, 0x5689)
if err != nil { ... }
defer keyboard.Close()

keyboard.KeyDown(vhid.KeyA)
keyboard.KeyUp(vhid.KeyA)
```

把指针放到指定位置再点击，用绝对定位鼠标：

```go
pointer, err := vhid.NewAbsoluteMouse(0x1234, 0x568A)
if err != nil { ... }
defer pointer.Close()

time.Sleep(2 * time.Second)
pointer.MoveToPixel(800, 450, 1920, 1080) // 屏幕是 1920x1080，放到像素 (800, 450)
pointer.Button(vhid.ButtonLeft, true)     // 在这个位置按下左键
pointer.Button(vhid.ButtonLeft, false)

pointer.MoveTo(vhid.AbsoluteMax/2, vhid.AbsoluteMax/2) // 不知道分辨率时：0..32767 表示从左上到右下
```

## 运行演示程序

前提：已经用测试包的 `install.cmd` 装好驱动。用管理员身份打开命令行：

```
winuhid-nodll-sample.exe                      创建鼠标和键盘，移动指针，按一下左 Shift
winuhid-nodll-sample.exe -type "Hello 123"    另外：倒数 5 秒后用虚拟键盘打字（先点到记事本里）
winuhid-nodll-sample.exe -click               另外：在指针所在位置按一下鼠标左键
```

这个 exe 可以拷到任何目录单独运行，旁边不需要放别的文件。

自己编译，进入 `examples/go-nodll` 目录后：

```
go build -o winuhid-nodll-sample.exe .                              在 Windows 上
GOOS=windows GOARCH=amd64 go build -o winuhid-nodll-sample.exe .    在 Mac 或 Linux 上交叉编译
```

## 和 `examples/go`（调 DLL 的示例）的区别

| | `examples/go` | `examples/go-nodll` |
| --- | --- | --- |
| 要随程序带的文件 | `WinUHid.dll`、`WinUHidDevs.dll` | 无 |
| 鼠标 | 用 `WinUHidDevs.dll` 里现成的相对鼠标 | 自己定义的五键鼠标，带滚轮和横向滚动；相对和绝对定位两种 |
| 滚轮单位 | 1/120 格 | 整格 |
| 手柄（PS4、PS5、Xbox） | `WinUHidDevs.dll` 里有，示例没用到 | 没有 |
| 驱动接口变了怎么办 | 换新的 DLL | 要跟着改 `vhid/device.go` |

## 要注意的地方

- **必须以管理员或 SYSTEM 身份运行。** 驱动只允许这两类身份创建虚拟设备，否则返回 `vhid.ErrAccessDenied`。
- **新设备创建后要等一下。** Windows 准备好设备之前发的输入会丢。演示程序的做法是反复试、直到看到指针动了。
- **厂商号和产品号要用自己的。** 示例里的 `0x1234` 只是占位，厂商号传 0 会被拒绝。
- **`-type` 按的是键位，不是字符。** 打出什么取决于目标窗口当前的键盘布局和输入法；开着中文输入法时字母会进输入法。
- **远程桌面会话里看不到效果。** 虚拟设备的输入进的是本机屏幕那个会话。
- **设备随进程存在。** 调 `Close` 或进程退出，设备就从系统里消失。
- **两种鼠标各有用途。** 相对鼠标 `Mouse` 移动多少像素受系统的指针速度和加速设置影响，不能精确定位，但只认相对移动的程序（很多游戏）需要它。绝对定位鼠标 `AbsoluteMouse` 直接把指针放到指定位置，不受这些设置影响。
- **绝对定位鼠标的按键和滚轮作用在上一次 `MoveTo` 的位置。** 它的每份数据都带着位置，所以要先 `MoveTo` 再按键；用户自己动过鼠标之后再按键，指针会回到上一次 `MoveTo` 的位置。
- **绝对定位的范围是主屏幕。** 多显示器时它对应哪块屏幕还没有测过。
- `vhid/device.go` 里的控制码和结构来自 `WinUHid Driver/Public.h`，驱动接口改了要同步改。
