@echo off
chcp 65001 >nul
setlocal EnableDelayedExpansion

REM =====================================================================
REM  固化开机自启：MeshCentral 系统服务 + cloudflared 系统服务
REM
REM  用途：让固定域名长期在线，开机后无需人工干预
REM  用法：双击本文件，UAC 弹窗点「是」，然后等它跑完
REM
REM  隧道 UUID 和域名都从现有配置自动读取，不需要手工填
REM =====================================================================

REM ---------- 可按需修改 ----------
set "MC_SVC=meshcentral.exe"
set "MC_DIR=C:\mesh"
set "PORT=3000"
set "CF=C:\Program Files (x86)\cloudflared\cloudflared.exe"

REM ---------- 自动提权 ----------
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo 需要管理员权限，正在请求提权，请在弹窗中点「是」...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

set "SYS=%SystemRoot%\System32\config\systemprofile\.cloudflared"
set "USR=%USERPROFILE%\.cloudflared"

echo.
echo ============ 开机自启固化 ============
echo.

REM ---------- 环境检查 ----------
if not exist "%CF%" (
    echo [错误] 找不到 cloudflared: %CF%
    echo        请先运行: winget install --id Cloudflare.cloudflared
    echo        若装在别的位置，请修改本脚本顶部的 CF 变量。
    pause
    exit /b 1
)
if not exist "%USR%\config.yml" (
    echo [错误] 找不到 %USR%\config.yml
    echo        请先按 README 第 8 步写好隧道配置。
    pause
    exit /b 1
)

REM ---------- 读取隧道凭据文件名 ----------
set "CREDFILE="
for %%f in ("%USR%\*.json") do set "CREDFILE=%%~nxf"
if not defined CREDFILE (
    echo [错误] %USR% 下没找到隧道凭据 *.json
    echo        请先执行: cloudflared tunnel create ^<隧道名^>
    pause
    exit /b 1
)
set "TID=!CREDFILE:~0,-5!"

REM ---------- 从 config.yml 解析入口域名 ----------
set "HOST="
for /f "tokens=3" %%h in ('findstr /c:"- hostname:" "%USR%\config.yml" 2^>nul') do if not defined HOST set "HOST=%%h"
if not defined HOST (
    echo [错误] 没能从 %USR%\config.yml 解析出 hostname
    echo        请确认配置里有 "- hostname: 你的域名" 这一行。
    pause
    exit /b 1
)

echo   隧道 UUID : !TID!
echo   凭据文件  : !CREDFILE!
echo   入口域名  : !HOST!
echo   服务端口  : %PORT%
echo.
pause

REM ---------- 1. 释放端口 ----------
echo [1/5] 释放 %PORT% 端口（停掉手动启动的临时实例）
powershell -NoProfile -Command "Get-NetTCPConnection -LocalPort %PORT% -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }"
timeout /t 3 /nobreak >nul

REM ---------- 2. MeshCentral 服务 ----------
echo [2/5] 启动 MeshCentral 服务
powershell -NoProfile -Command "if (-not (Get-Service -Name '%MC_SVC%' -ErrorAction SilentlyContinue)) { exit 1 }"
if errorlevel 1 (
    echo       服务未注册，先注册（需要 %MC_DIR% 已装好 meshcentral）...
    pushd "%MC_DIR%"
    call node node_modules\meshcentral --install
    popd
    timeout /t 15 /nobreak >nul
)
net start "%MC_SVC%" >nul 2>&1
timeout /t 20 /nobreak >nul

REM ---------- 3. 系统级配置目录 ----------
echo [3/5] 准备系统级配置目录
echo       %SYS%
if not exist "%SYS%" mkdir "%SYS%"
copy /Y "%USR%\!CREDFILE!" "%SYS%\!CREDFILE!" >nul
if exist "%USR%\cert.pem" copy /Y "%USR%\cert.pem" "%SYS%\cert.pem" >nul

REM cloudflared 服务以 LocalSystem 运行，只读这个系统级目录，
REM 所以凭据路径必须是绝对路径的这一个副本。
> "%SYS%\config.yml" echo tunnel: !TID!
>>"%SYS%\config.yml" echo credentials-file: %SYS%\!CREDFILE!
>>"%SYS%\config.yml" echo.
>>"%SYS%\config.yml" echo ingress:
>>"%SYS%\config.yml" echo   - hostname: !HOST!
>>"%SYS%\config.yml" echo     service: https://127.0.0.1:%PORT%
>>"%SYS%\config.yml" echo     originRequest:
>>"%SYS%\config.yml" echo       noTLSVerify: true
>>"%SYS%\config.yml" echo   - service: http_status:404
echo       已生成 %SYS%\config.yml

REM ---------- 4. 注册 cloudflared 服务 ----------
echo [4/5] 注册 cloudflared 服务
"%CF%" service install

REM ---------- 5. 修正注册表并启动 ----------
echo [5/5] 修正服务配置路径并启动
reg add "HKLM\SYSTEM\CurrentControlSet\Services\Cloudflared" /v ImagePath /t REG_EXPAND_SZ /d "\"%CF%\" --config=\"%SYS%\config.yml\" tunnel run" /f >nul
net stop cloudflared >nul 2>&1
timeout /t 3 /nobreak >nul
net start cloudflared

echo.
echo ============ 状态确认 ============
powershell -NoProfile -Command "Get-Service '%MC_SVC%','Cloudflared' | Format-Table Name,Status,StartType -AutoSize"
echo.
echo 本机服务探测：
powershell -NoProfile -Command "try { 'HTTP ' + (Invoke-WebRequest -Uri 'https://127.0.0.1:%PORT%/' -SkipCertificateCheck -TimeoutSec 8).StatusCode } catch { '还没起来，等 30 秒后重开 https://127.0.0.1:%PORT% 看看' }" 2>nul
echo.
echo 固定访问地址: https://!HOST!
echo.
echo 两个服务都设为开机自启，以后不用再跑这个脚本。
echo.
pause
endlocal
