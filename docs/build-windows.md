# 在 Windows 上构建 SyncNotes 客户端（新手版）

本文适用于 Windows 10 / 11（64 位），从一台全新的电脑开始，最后得到 `SyncNotes-windows-x64.zip` 并上传到 GitHub 发布页。
目录结构和 CI 构建的完全一致。全程大约需要 1–2 小时，大部分时间在下载和安装 Visual Studio。

下面的命令都在 **PowerShell** 中执行：按 `Win` 键，输入 `PowerShell`，打开"Windows PowerShell"。
每装完一个软件，**关掉 PowerShell 再重新打开**，新的 PATH 才会生效。

---

## 1. 安装 Git

1. 打开 <https://git-scm.com/download/win>，下载 "64-bit Git for Windows Setup"
2. 双击安装，所有选项保持默认，一路"Next"
3. 重新打开 PowerShell，检查：
   ```powershell
   git --version
   ```
   显示 `git version 2.x.x` 即成功

## 2. 安装 Visual Studio 2022 Community（C++ 编译器）

Flutter 的 Windows 程序要用微软的 C++ 编译器编译。注意：要装的是 **Visual Studio**，不是 Visual Studio Code。

1. 打开 <https://visualstudio.microsoft.com/zh-hans/downloads/>，下载 **Visual Studio 2022 Community**（免费）
2. 运行安装程序，在"工作负荷"页勾选 **"使用 C++ 的桌面开发"**（Desktop development with C++）
3. 右侧"安装详细信息"保持默认，确认其中包含：
   - MSVC v143 - VS 2022 C++ x64/x86 生成工具
   - Windows 11 SDK（或 Windows 10 SDK）
   - 用于 Windows 的 C++ CMake 工具
4. 点击"安装"，大约需要 8–10 GB 空间，安装完成后重启电脑

## 3. 开启"开发人员模式"

Flutter 插件需要创建符号链接，没有开启时会报 `Building with plugins requires symlink support`。

- Windows 11：设置 → 系统 → 开发者选项 → 打开 **开发人员模式**
- Windows 10：设置 → 更新和安全 → 开发者选项 → 选择 **开发人员模式**

也可以在 PowerShell 中运行 `start ms-settings:developers` 直接打开这个页面。

## 4. 安装 Flutter SDK（必须是 3.44.8）

本仓库固定使用 **Flutter 3.44.8（stable）**，见 `.github/workflows/build.yml` 中的 `FLUTTER_VERSION`。版本不同可能编译失败，或者界面和发布版不一致。

### 4.1（可选）国内网络：使用镜像

如果访问 Google 很慢或打不开，先设置两个环境变量（写入用户环境变量，永久生效）：

```powershell
[Environment]::SetEnvironmentVariable("PUB_HOSTED_URL", "https://pub.flutter-io.cn", "User")
[Environment]::SetEnvironmentVariable("FLUTTER_STORAGE_BASE_URL", "https://storage.flutter-io.cn", "User")
```

备选镜像（上面的不能用时换成这一组）：

```powershell
[Environment]::SetEnvironmentVariable("PUB_HOSTED_URL", "https://mirrors.tuna.tsinghua.edu.cn/dart-pub", "User")
[Environment]::SetEnvironmentVariable("FLUTTER_STORAGE_BASE_URL", "https://mirrors.tuna.tsinghua.edu.cn/flutter", "User")
```

设置后重新打开 PowerShell，用 `echo $env:PUB_HOSTED_URL` 确认已生效。

### 4.2 下载并解压

下载 Flutter 3.44.8 的 Windows 压缩包（二选一）：

- 官方：<https://storage.googleapis.com/flutter_infra_release/releases/stable/windows/flutter_windows_3.44.8-stable.zip>
- 国内镜像：<https://storage.flutter-io.cn/flutter_infra_release/releases/stable/windows/flutter_windows_3.44.8-stable.zip>

解压到 `C:\src\flutter`，确认存在 `C:\src\flutter\bin\flutter.bat`。

> 不要放在 `C:\Program Files` 这类需要管理员权限的目录，路径中也不要有中文或空格。

也可以用 Git 直接拉取指定版本：

```powershell
mkdir C:\src
git clone -b 3.44.8 --depth 1 https://github.com/flutter/flutter.git C:\src\flutter
```

### 4.3 加入 PATH

```powershell
$p = [Environment]::GetEnvironmentVariable("Path", "User")
[Environment]::SetEnvironmentVariable("Path", "$p;C:\src\flutter\bin", "User")
```

重新打开 PowerShell，检查版本：

```powershell
flutter --version
```

第一行必须是 `Flutter 3.44.8 • channel stable`。第一次运行会下载 Dart SDK，需要等几分钟。

### 4.4 运行 flutter doctor

```powershell
flutter config --enable-windows-desktop
flutter doctor -v
```

只需要这两项是绿色的 `[√]`：

- `Flutter (Channel stable, 3.44.8 ...)`
- `Visual Studio - develop Windows apps (Visual Studio Community 2022 ...)`

Android toolchain、Chrome 等显示 `[X]` 或 `[!]` 都不影响构建 Windows 客户端。

## 5. 获取代码（私有仓库）

仓库 `boochain/syncnotes` 是私有的，需要先登录 GitHub。推荐安装 GitHub CLI，后面上传发布文件也要用到它。

### 方法 A：GitHub CLI（推荐）

1. 打开 <https://cli.github.com/>，下载并安装 Windows 版（或执行 `winget install --id GitHub.cli`）
2. 重新打开 PowerShell，登录：
   ```powershell
   gh auth login
   ```
   依次选择：`GitHub.com` → `HTTPS` → `Y`（用 GitHub 凭据登录 Git）→ `Login with a web browser`。
   复制屏幕上的 8 位代码，按回车会打开浏览器，粘贴代码并授权
3. 克隆仓库并切换到发布标签：
   ```powershell
   cd C:\src
   gh repo clone boochain/syncnotes
   cd syncnotes
   git checkout v0.4.0
   ```
   提示 `You are in 'detached HEAD' state` 是正常的。

### 方法 B：个人访问令牌（PAT）

1. 浏览器打开 <https://github.com/settings/tokens?type=beta>，点击 "Generate new token"
2. Repository access 选 "Only select repositories" → `boochain/syncnotes`；Permissions → Contents 选 **Read and write**（之后上传发布文件需要写权限）
3. 生成后复制令牌（只显示一次）
4. 克隆：
   ```powershell
   cd C:\src
   git clone https://github.com/boochain/syncnotes.git
   ```
   弹出登录窗口时，选择用令牌登录并粘贴令牌（或者用户名填 GitHub 用户名、密码填令牌）
5. `cd syncnotes; git checkout v0.4.0`

## 6. 构建

```powershell
cd C:\src\syncnotes\app
flutter pub get
flutter build windows --release
```

第一次构建需要 5–15 分钟。成功时最后一行类似：

```
√ Built build\windows\x64\runner\Release\syncnotes.exe
```

输出目录是 `app\build\windows\x64\runner\Release\`，里面有：

| 文件 | 作用 |
|---|---|
| `syncnotes.exe` | 主程序 |
| `flutter_windows.dll` | Flutter 引擎 |
| 其他 `*.dll`（如 `tray_manager_plugin.dll`、`window_manager_plugin.dll` 以及通知等插件的 DLL） | 各插件的原生代码，必须和 exe 放在一起 |
| `data\app.so` | 编译后的 Dart 代码 |
| `data\icudtl.dat` | 文字和国际化数据 |
| `data\flutter_assets\` | 图标、字体，以及 Liquid Glass 玻璃效果的**着色器**（`shaders\` 等） |

**不要只拿 `syncnotes.exe`**，整个 `Release` 文件夹缺一不可。

## 7. 打包成 zip（与 CI 完全一致）

回到仓库根目录，运行打包脚本：

```powershell
cd C:\src\syncnotes
powershell -ExecutionPolicy Bypass -File scripts\package-windows.ps1
```

（也可以加 `-Build` 参数，让脚本先执行 `flutter pub get` 和 `flutter build windows --release`。）

脚本做的事情和 CI 一样：

1. 把 `app\build\windows\x64\runner\Release` 复制为 `SyncNotes\` 文件夹
2. 从 `C:\Windows\System32` 复制 VC++ 运行库 `msvcp140.dll`、`vcruntime140.dll`、`vcruntime140_1.dll` 到 `SyncNotes\`，没有安装 VC++ 运行库的电脑也能直接打开
3. 检查 `syncnotes.exe` 和 `data\app.so` 是否存在
4. 压缩成 `dist\SyncNotes-windows-x64.zip`（zip 里只有一个顶层文件夹 `SyncNotes\`），并显示 SHA256

## 8. 测试能否运行

1. 在资源管理器中把 `dist\SyncNotes-windows-x64.zip` 解压到一个**新**文件夹（例如桌面）
2. 双击 `SyncNotes\syncnotes.exe`
3. 检查：
   - 出现登录页，可以输入服务器地址并登录
   - 收件箱、页面、斜杠菜单（在页面里输入 `/`）、Ctrl+K 快速查找都正常
   - 任务栏右下角出现托盘图标；关闭窗口后程序仍在托盘中，点击托盘图标可以重新打开
   - 设置 → 关于中显示版本 0.4.0
4. 最好在另一台没有装过 Visual Studio 的电脑上也试一次，确认不缺 DLL

## 9. 上传到 GitHub 发布页

```powershell
cd C:\src\syncnotes
gh release upload v0.4.0 dist\SyncNotes-windows-x64.zip
```

然后把 Windows 包的校验和加入 `SHA256SUMS.txt`：

```powershell
gh release download v0.4.0 -p SHA256SUMS.txt -D dist --clobber
$hash = (Get-FileHash -Algorithm SHA256 dist\SyncNotes-windows-x64.zip).Hash.ToLower()
$lines = Get-Content dist\SHA256SUMS.txt | Where-Object { $_ -notmatch "SyncNotes-windows-x64.zip" }
$lines + "$hash  SyncNotes-windows-x64.zip" | Set-Content -Encoding ascii dist\SHA256SUMS.txt
gh release upload v0.4.0 dist\SHA256SUMS.txt --clobber
```

> 如果要替换已经上传的 zip，在第一条命令后面加 `--clobber`。

最后打开 <https://github.com/boochain/syncnotes/releases/tag/v0.4.0>，确认列表中出现 `SyncNotes-windows-x64.zip`。

## 10. 常见问题

| 现象 | 解决方法 |
|---|---|
| `flutter : 无法将"flutter"项识别为 cmdlet…` | PATH 没设置好或没重开 PowerShell。检查 `C:\src\flutter\bin\flutter.bat` 是否存在，重新执行 4.3 并重开 PowerShell |
| `flutter --version` 不是 3.44.8 | 电脑上有别的 Flutter。运行 `where.exe flutter` 查看，删掉旧的 PATH 项；或在 `C:\src\flutter` 中执行 `git fetch --tags; git checkout 3.44.8` |
| `Unable to find suitable Visual Studio toolchain` | 没装"使用 C++ 的桌面开发"工作负荷。打开 Visual Studio Installer → 修改 → 勾选后安装，然后重启电脑 |
| `Building with plugins requires symlink support` | 没有开启开发人员模式，见第 3 步 |
| `pub get` 卡住或报 `Connection closed` / `SocketException` | 网络问题。设置 4.1 的镜像后重开 PowerShell；也可以设置代理：`$env:HTTPS_PROXY="http://127.0.0.1:7890"`（换成你的代理端口） |
| 第一次运行 `flutter` 时下载 Dart SDK 失败 | 同上，设置 `FLUTTER_STORAGE_BASE_URL` 镜像 |
| `CMake Error` / `MSB8066` / 路径相关错误 | 仓库或 Flutter 路径中有中文或空格。移到 `C:\src\` 下重试，并先执行 `flutter clean` |
| `LNK1104: 无法打开文件 syncnotes.exe` | 程序还开着（可能在托盘里）。右键托盘图标退出，或用任务管理器结束 `syncnotes.exe`，再构建 |
| 构建报错但看不出原因 | `cd app; flutter clean; flutter pub get; flutter build windows --release -v`，查看详细日志中第一个 `error` |
| `git clone` 报 `Repository not found` | 没登录或令牌没有该仓库的权限，重新执行 `gh auth login`，或重新生成令牌并选中 `boochain/syncnotes` |
| 运行脚本提示"在此系统上禁止运行脚本" | 按第 7 步用 `powershell -ExecutionPolicy Bypass -File ...` 运行 |
| 双击 exe 提示缺少 `VCRUNTIME140.dll` / `MSVCP140.dll` | 用了 Release 文件夹而不是打包后的 zip。用 `scripts\package-windows.ps1` 打包，或安装 VC++ Redistributable (x64) |
| 打开后窗口空白或闪退 | 确认整个文件夹都在（特别是 `data\`）；可以在 PowerShell 中运行 `.\syncnotes.exe` 查看输出。玻璃效果异常时可以设置 `$env:SYNCNOTES_GLASS="0"` 再运行，换成普通背景 |
| `gh release upload` 报 `already exists` | 加 `--clobber` 覆盖 |
| `gh release upload` 报 `HTTP 403` | 令牌只有读权限。PAT 需要 Contents: Read and write；用 gh 登录的账号需要有仓库写权限 |
