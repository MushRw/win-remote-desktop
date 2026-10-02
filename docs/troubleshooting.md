# 排错手册

本文档里的每一条都是实际部署时踩过的坑，不是理论推测。

---

## 一、MeshCentral 相关

### 服务名不叫 `MeshCentral`

`node node_modules\meshcentral --install` 注册出来的服务名是 **`meshcentral.exe`**（带点号）。用 `Get-Service MeshCentral` 查会查不到。

```powershell
Get-Service meshcentral.exe
```

守护进程在 `<安装目录>\WinService\daemon\meshcentral.exe`（node-windows 生成的包装器），账户是 `LocalSystem`，`StartMode` 为 `Auto`，所以**开机后不用登录就会自启**。

### 端口会自己跳到 3001

3000 被占用时，MeshCentral **不会报错退出**，而是静默顺延到下一个可用端口（日志里会写 `HTTPS server running on xxx:3001`）。

排查：

```powershell
netstat -ano | findstr :3000
```

拿到 PID 后清掉占用进程再重启服务。要避免这个问题，可以用 `--exactports` 参数强制它「端口不对就退出」，而不是顺延。

### 日志里出现 `LAN mode` 而不是 `Hybrid`

说明配置里的 `cert` 是个**不带点号**的名字（比如 `desk`），MeshCentral 会判定当前是局域网环境，于是：

- 降级为 LAN-only 模式
- **丢掉默认 STUN 服务器**，导致内网穿透更容易失败

修法：把 `cert` 改成带点号的 FQDN 形式，比如 `desk.example.com`（不需要真的能解析）。

### 登录后报「HTTP 请求中的无效来源, 点击重新连接」

页面能打开、能输密码，但一进去就弹这句，实际是主控制通道 `control.ashx` 的 **WebSocket 来源校验**没过。服务端会下发：

```json
{"action":"close","cause":"invalidorigin","msg":"invalidorigin"}
```

判定逻辑在 `webserver.js`：

```js
obj.CheckWebServerOriginName = function (domain, req) {
    if (domain.allowedorigin === true) return true;
    if (typeof req.headers.origin != 'string') return true;   // 无 Origin 头 = 桌面客户端
    if (Array.isArray(domain.allowedorigin)) return (domain.allowedorigin.indexOf(originUrl.hostname) >= 0);
    if (domain.dns != null) return (domain.dns == originUrl.hostname);
    return (obj.getWebServerName(domain, req) == originUrl.hostname);
}
```

而 `getWebServerName()` 在没有配 `dns` 时返回的是**证书 CN** —— 只有当 CN 恰好是 `un-configured` 才会退回用 `Host` 头。

于是就形成一个死结：**为了让 MeshCentral 脱离 LAN-only 模式，你把 `cert` 设成了一个人造 FQDN**（`desk.example.com`），浏览器发来的 `Origin: https://你的真实域名` 自然永远对不上，连接被拒。

修法：在 domain 里显式列出允许的来源主机名，然后重启 MeshCentral。

```json
"domains": {
  "": {
    "allowedorigin": "desk.example.com,localhost,127.0.0.1"
  }
}
```

- 逗号分隔，**别带空格**（源码是直接 `split(',')`，不去空格）
- 必须包含**公网域名**；`localhost` / `127.0.0.1` 是为了让本机浏览器也能登录（装 Mesh Agent 时要用）
- 不建议用 `"allowedorigin": true` 整个跳过

**不动浏览器、不装任何东西的验证方法**：MeshCentral 自带 `ws` 依赖，在程序目录下建个脚本直接发起握手。

```js
// _wstest.js  —— 放到 <程序目录> 下执行：node _wstest.js
const WebSocket = require('ws');
const ws = new WebSocket('wss://127.0.0.1:3000/control.ashx', {
  origin: 'https://你的域名',
  rejectUnauthorized: false
});
ws.on('open',  () => console.log('握手 HTTP 101 成功'));
ws.on('message', d => console.log('服务端说:', d.toString()));
```

判读结果：

| 返回 | 含义 |
| --- | --- |
| `invalidorigin` | 来源校验没过，按上面的修 |
| `noauth` | **来源校验已通过**，只是没带登录 Cookie —— 这正是期望结果 |

### 非管理员管不动这个服务

服务跑在 `LocalSystem` 下。如果你的登录账号不在管理员组：

- `Stop-Service` 不报错但状态仍是 `Running`
- `taskkill /F` 报「拒绝访问」
- `node node_modules\meshcentral --restart` 抛 node-windows 的 daemon 错误

**唯一可靠的办法是用管理员身份操作**，或者重启机器。

另外：如果服务被强杀，node-windows 包装器的 `--maxrestarts`（默认 3 次）会耗尽，服务会变成 `Stopped` 且不再自动拉起。

### `sc.exe` 不可用

部分环境（沙箱、受限策略）会把 `sc.exe` 拉黑。改用 PowerShell：

```powershell
Get-CimInstance Win32_Service -Filter "Name='meshcentral.exe'"
Get-Service meshcentral.exe
```

---

## 二、Cloudflare Tunnel 相关

### `x509: certificate signed by unknown authority`

cloudflared 默认会校验回源证书，而 MeshCentral 用的是自签证书。

修法：在 `config.yml` 的对应 hostname 下加：

```yaml
    originRequest:
      noTLSVerify: true
```

注意**缩进**。它必须是 `hostname` 那一项的兄弟节点，写错层级不生效。

这是这套方案唯一需要「跳过校验」的地方。它只跳过**本机这一段**，浏览器看到的仍是 Cloudflare 边缘签发的真证书，不影响外部安全。

### `dial tcp [::1]:3000: connect: connection refused`

配置里 `service` 写成了 `localhost`。cloudflared 会把 `localhost` 优先解析成 IPv6 的 `::1`，而 MeshCentral 只监听 IPv4。

修法：写死 `127.0.0.1`。

### 命令报 `context deadline exceeded`

本机有 HTTP 代理在拦 cloudflared 的 API 调用（`tunnel create` / `tunnel route dns` 这类）。

绕开：

```bash
env -u http_proxy -u https_proxy -u HTTP_PROXY -u HTTPS_PROXY cloudflared tunnel create desk
```

Windows 下也可以在命令提示符里临时清：

```bat
set http_proxy=
set https_proxy=
cloudflared tunnel create desk
```

注意：`tunnel run` 一般不受影响，因为它是直接建出站长连接。

### 登录授权链接超时

`cloudflared tunnel login` 打印的链接**约 8 分钟失效**，超时会报 `Failed to write the certificate`。而且每次执行链接都不同，必须重新发起。

授权成功后证书落在 `%USERPROFILE%\.cloudflared\cert.pem`。

> 冷知识：这个 `cert.pem` 其实**不是 X.509 证书**，而是一个 `-----BEGIN ARGO TUNNEL TOKEN-----` 的令牌，base64 里带着 zoneID / accountID / apiToken。所以 `curl --cert cert.pem` 这类用法是不成立的。

### 页面 502

按顺序查：

1. 本机 MeshCentral 起没起 → 浏览器打开 `https://127.0.0.1:3000`
2. 没起 → `net start meshcentral.exe`
3. 起了还 502 → 看 cloudflared 日志里有没有 `Unable to reach the origin service`

### 想不配域名临时用一下：Quick Tunnel

```powershell
cloudflared tunnel --url https://127.0.0.1:3000 --no-tls-verify
```

- **完全不需要 Cloudflare 账号**
- 终端会打印一个 `https://xxx.trycloudflare.com`

代价（官方明确定位为 dev 用途）：

| 限制 | 说明 |
| --- | --- |
| 地址每次都变 | 存书签没用 |
| 进程关了即断 | 约 5 分钟无连接会被回收 |
| 只有 HTTP/HTTPS | 不支持 RDP / SSH 这类 L4 服务 |
| 约 200 并发上限 | 不支持 SSE |

---

## 三、Windows 服务相关

### cloudflared 服务读不到配置

**cloudflared 以 `LocalSystem` 运行，只读 `%SystemRoot%\System32\config\systemprofile\.cloudflared\` 下的 `config.yml`**，这是官方文档的硬要求。

放在 `%USERPROFILE%\.cloudflared\` 那份它读不到——那份是给你手动运行 `cloudflared tunnel run` 用的。

两份内容等价，只是 `credentials-file` 的绝对路径不同。`scripts/setup-autostart.bat` 会自动生成系统级那一份。

### 不要用 `cloudflared service install`（会覆盖已有的隧道服务）

`cloudflared service install` 固定使用服务名 **`Cloudflared`**。

如果机器上已经有一条 dashboard 托管的隧道服务在跑，这条命令会直接覆盖它的 ImagePath；而 `cloudflared service uninstall` 会把它整个删掉。

自检：

```powershell
Get-CimInstance Win32_Service -Filter "Name='Cloudflared'" |
  Select-Object Name, State, PathName | Format-List
```

看 `PathName` 结尾是 `--token xxxxx` 还是 `--config=...`。前者说明是 dashboard 托管的隧道，**别动它**。

本方案因此创建独立服务 `CloudflaredDesk`：

```powershell
Get-CimInstance Win32_Service -Filter "Name='CloudflaredDesk'" |
  Select-Object Name, State, PathName | Format-List
```

### 搬迁程序目录之后

MeshCentral 的服务注册里写死了 `WinService\daemon\meshcentral.exe` 的**绝对路径**，所以把程序目录移到别处之后：

1. 旧服务会启动失败（找不到可执行文件）
2. 需要以管理员身份重新跑一次 `scripts/setup-autostart.bat`。它会检测到服务路径已失效，自动 `sc delete` 旧注册，再从新位置执行 `--install`
3. 隧道服务 `CloudflaredDesk` 的 `--config` 指向系统级目录，与程序目录无关，**不需改动**，但重启一下更稳妥

搬迁前先停掉手动运行的实例，否则文件被占用：

```powershell
Get-NetTCPConnection -LocalPort 3000 -State Listen -ErrorAction SilentlyContinue |
  Select-Object -ExpandProperty OwningProcess -Unique |
  ForEach-Object { Stop-Process -Id $_ -Force }
```

拷贝整个程序目录用 `robocopy`（能处理 node_modules 里的超长路径）：

```powershell
robocopy "C:\mesh" "D:\code\deskremote\app" /E /R:1 /W:1 /MT:16
```

> **注意**：不要在 Git Bash（MSYS）里跑这条命令。MSYS 的路径自动转换会把 `/E` 这类参数和 `E:\` 开头的目标路径搞乱，报「错误: 无效参数 #3」，然后什么也没拷。用 PowerShell 或 cmd。

搬迁完成后核对一下：

```powershell
# 文件数应一致
(Get-ChildItem -Recurse -File "C:\mesh").Count
(Get-ChildItem -Recurse -File "D:\code\deskremote\app").Count
```

确认无误再删除旧目录。

### 改了配置怎么生效

```bat
net stop cloudflared
net start cloudflared
```

（需要管理员）

### 服务注册要管理员

`sc create`、`cloudflared service install`、node-windows 的 `--install` 都需要管理员权限，绕不过去。`setup-autostart.bat` 里已经内置了自提权（`Start-Process -Verb RunAs`），双击即可。

### `%USERPROFILE%` 在高权限窗口里指向不对

如果用**另一个**管理员账号提权运行脚本，`%USERPROFILE%` 会指向那个账号的目录，导致找不到隧道凭据。

修法：用当前账号（管理员组成员）右键「以管理员身份运行」，或者手工改脚本里的 `USR` 变量。

---

## 四、使用体验相关

### 中文打不出来

这是这套方案**最大的短板**。

浏览器里的 RDP 类客户端无法运行远端输入法。MeshCentral 有 text input 模式，能让本机输入法反推按键发过去，但中文场景仍不稳定。

**最稳的兜底：走剪贴板粘贴。** 需要打大段中文时，在本机打好复制，然后在远端粘贴。

如果你主要需求就是码中文，建议改用原生 RDP 客户端（mstsc），或换 Tailscale / WireGuard 打点对点之后直接用系统远程桌面。

### 画面卡、像幻灯片

抓屏是逐帧压缩后经 WebSocket 传的，远端看视频会非常卡。办公、改代码、看网页都没问题。

### 用 Firefox 各种不正常

剪贴板直连不可用、部分组合键（如 `Ctrl+W`）失效、缩放会糊、不能拖文件。

**用 Chrome 或 Edge。**

### 手机/平板上操作别扭

触屏下是相对/绝对指针模拟，双指缩放、长按右键都做了适配，但精细操作仍不如鼠标。用 MeshCentral 内置的屏幕键盘可以补发 `Ctrl+Alt+Del`、`Alt+Tab` 这类被本地系统截走的组合键。

### 操作延迟高

先分清瓶颈在哪：**大多数情况下是你家宽带的上行带宽**（常见 30~50 Mbps），而不是隧道本身。

Cloudflare 隧道因为多一跳边缘节点，延迟天然比直连高。要低延迟的点对点串流，应该用 Tailscale / WireGuard，而不是隧道。

---

## 五、流程类问题

### 长驻进程用后台任务跑会被回收

如果用脚本/工具起的进程带了 `nohup ... &`，父命令结束时子进程可能被一起回收。Windows 下要长驻，正确做法是**注册成系统服务**，这也正是 `setup-autostart.bat` 存在的意义。

### 反复启动会留下孤儿进程

MeshCentral v1.x 会 fork 子进程。反复启动又没清干净的话，会出现多个实例同时占 3000 / 3001 / 3002，日志互相覆盖，排查时极具迷惑性。

排查：

```powershell
Get-CimInstance Win32_Process -Filter "Name='node.exe'" |
  Where-Object { $_.CommandLine -like '*meshcentral*' } |
  Format-Table ProcessId, ParentProcessId, CommandLine -AutoSize
```

清干净再启动。

**关键陷阱：只杀监听端口的那个子进程没用。**

父子进程的关系是 `父 PPID=xxx → 子`，真正监听 3000 的是**子进程**。如果只按端口找到 PID 杀掉子进程，父进程还活着，会**立刻拉起一个新的子进程重新抢占 3000**；而你紧接着启动的新实例抢不到端口，就静默顺延到 **3001** —— 于是你以为改的配置没生效，其实生效在另一个端口上。

`netstat` 里能同时看到 3000 和 3001 各占一个 PID，就是这种情况。

正确做法是**把父子都杀掉**（用上面的 `Get-CimInstance` 列出来的所有 PID 一起 `Stop-Process`），确认 3000 / 3001 / 4433 / 81 全部释放，再启动单个实例。

判断是否只剩单实例，看启动日志里这几行同时出现即可（端口无 `not available` 报错）：

```
MeshCentral HTTP redirection server running on port 80.
MeshCentral v1.2.5, Hybrid (LAN + WAN) mode.
MeshCentral Intel(R) AMT server running on desk.example.com:4433.
MeshCentral HTTPS server running on desk.example.com:3000.
```
