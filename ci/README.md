# 开发验证流水线

每次推送到 `main`，GitHub Actions 自动跑 `.github/workflows/dev-msi.yml`：

| 阶段 | 在哪台机器 | 做什么 |
| --- | --- | --- |
| build | Server 2022 | 编译驱动和调用库；临时生成一张测试证书给驱动包签名；打包 MSI；编译 Go 示例；组装测试包 |
| install-test | Server 2022、Server 2025 各一台干净机器 | 按测试人员的步骤走一遍：`install.cmd` → `selftest.cmd` → 两个 Go 示例程序（调 DLL 的、不带 DLL 的）→ `uninstall.cmd` |
| report | — | 把各阶段的报告和日志摘要写到 `ci-results` 分支 |
| release | — | 全部通过后，更新 Releases 里的 `dev-test` 预发布 |

同一个 MSI 里有两套安装规则：Server 2022 走 Windows 10 那套，Server 2025 走 Windows 11 那套，所以两台都要测。

## 去哪看结果

- 测试包下载：仓库 Releases 页的 `dev-test`（只在全部通过时更新）
- 最近一次构建的报告和日志：`ci-results` 分支的 `README.md`（开头是汇总：每个阶段通过和失败的检查数、失败的是哪几项）和 `logs/`
- 完整日志：Actions 页面对应的那次运行

## 验证状态（2026-10-03）

| 项目 | 在哪里验证的 |
| --- | --- |
| 编译、测试签名、打包 | 流水线，每次构建 |
| 安装、自检、卸载：Windows 10 那套规则 | 流水线，Windows Server 2022 |
| 安装、自检、卸载：Windows 11 那套规则 | 流水线，Windows Server 2025 |
| `install.cmd` 的两种用法：等按键确认、`/y` 不等 | 流水线（按键是脚本喂进去的，不是真人按的） |
| 两个 Go 示例；HTTP 参考程序以管理员和 SYSTEM 两种身份运行 | 流水线，两台构建机 |
| **不开测试模式也能安装** | 仓库所有者在自己的桌面版 Windows 10 上安装成功（具体版本号和安全启动状态没有记录） |

构建机都开着测试模式、没开安全启动，所以"不开测试模式能安装"这一条流水线证明不了，靠的是上面最后一行。

还没有验证过的：

- 桌面版 Windows 11
- 不开测试模式的机器上，自检和示例程序是否全部通过（目前只确认了安装成功）
- 多显示器；显示缩放不是 100% 的屏幕
- Windows 远程桌面会话里的表现；UAC 提示框、锁屏界面、Ctrl+Alt+Del
- 开了智能应用控制、S 模式或企业应用白名单的机器
- ARM64
- 正式代码签名（现在全部是测试签名）

## 测试包只能用于测试机

- 证书是每次构建临时生成的自签名证书，私钥不可导出，构建机销毁后就不存在了
- 它不是正式签名，**不要发给用户，不要装在生产机器上**
- 正式发布要换成公司主体的代码签名
- GitHub 的构建机本身开着测试模式，所以"普通机器不开测试模式也能安装"需要在真实的 Windows 机器上确认

测试包的使用方法见 `kit/README.txt`。

## 文件说明

| 文件 | 作用 |
| --- | --- |
| `lib.ps1` | 各脚本共用的函数 |
| `toolchain-report.ps1` | 记录构建机上的编译器、WDK、签名工具版本 |
| `ensure-wdk.ps1` | 构建机缺驱动开发套件时自动安装 |
| `new-test-cert.ps1` | 生成本次构建专用的测试证书 |
| `msbuild-project.ps1` | 编译单个项目并保存日志 |
| `sign-package.ps1` | 给驱动 DLL 和目录文件签名并校验 |
| `build-msi.ps1` | 打包 MSI，并拆开确认里面是签过名的文件 |
| `assemble-kit.ps1` | 组装测试包（MSI、证书、脚本、调用库、头文件） |
| `install-test.ps1` | 在干净机器上执行测试包里的安装、自检、卸载，并检查结果 |
| `http-sample-test.ps1` | 以管理员和 SYSTEM 两种身份运行 HTTP 参考程序，用桌面上的测试窗口确认点击和打字真的到达 |
| `publish-results.sh` | 把报告和日志摘要推到 `ci-results` 分支 |
| `release-notes.md` | `dev-test` 预发布页面上的说明文字 |
| `kit/` | 原样放进测试包的文件：安装、自检、卸载脚本和说明 |
