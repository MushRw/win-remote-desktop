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

### 改了配置怎么生效

```bat
net stop cloudflared
net start cloudflared
```

（需要管理员）

### 服务注册要管理员

`cloudflared service install` 和 node-windows 的 `--install` 都需要管理员权限，绕不过去。`setup-autostart.bat` 里已经内置了自提权。

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
