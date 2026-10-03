# 开发验证流水线

每次推送到 `main`，GitHub Actions 会自动：

1. 编译用户态驱动 `WinUHidDriver.dll` 和两个调用库 `WinUHid.dll`、`WinUHidDevs.dll`
2. 在本次构建里临时生成一张测试证书，给驱动包签名
3. 打包成 MSI
4. 在构建机上直接安装这个 MSI，创建一个虚拟鼠标和一个虚拟键盘，再卸载

构建结果在仓库 Actions 页面里对应那次运行的 Artifacts 下载，同时摘要会推到 `ci-results/<系统镜像>` 分支。

## 这个 MSI 只能用于测试机

- 证书是每次构建临时生成的自签名证书，私钥不可导出，构建机销毁后就不存在了
- 它不是正式签名，**不要发给用户，不要装在生产机器上**
- 正式发布要换成公司主体的代码签名

## 在测试机上安装

需要：64 位 Windows 10 2004 及以上或 Windows 11，管理员权限。不需要开启测试模式，不需要关闭安全启动。

用管理员身份打开 PowerShell，进入解压后的目录：

```powershell
# 1. 信任这次构建的测试证书（每次构建的证书都不同，换了新的 MSI 就要重新导入）
certutil -addstore -f Root WinUHid-dev-test.cer

# 2. 安装
msiexec /i WinUHid-dev-test-x64.msi /l*v install.log

# 3. 检查控制设备是否出现
pnputil /enum-devices /class System | findstr /i WinUHid
```

## 测试完清理

```powershell
msiexec /x WinUHid-dev-test-x64.msi
certutil -delstore Root "WinUHid Dev Test"
certutil -delstore TrustedPublisher "WinUHid Dev Test"
```

## 脚本说明

| 脚本 | 作用 |
| --- | --- |
| `toolchain-report.ps1` | 记录构建机上的编译器、WDK、签名工具版本 |
| `ensure-wdk.ps1` | 构建机缺驱动开发套件时自动安装 |
| `new-test-cert.ps1` | 生成本次构建专用的测试证书 |
| `msbuild-project.ps1` | 编译单个项目并保存日志 |
| `sign-package.ps1` | 给驱动 DLL 和目录文件签名并校验 |
| `build-msi.ps1` | 打包 MSI，并拆开确认里面是签过名的文件 |
| `smoke-test.ps1` | 在构建机上安装、创建虚拟鼠标和键盘、卸载 |
| `publish-results.ps1` | 把报告和日志摘要推到 `ci-results/*` 分支 |
