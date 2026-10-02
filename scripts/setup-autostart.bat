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
REM
REM  ⚠ 本脚本创建的是名为 CloudflaredDesk 的【独立】服务。
REM    若机器上已存在 cloudflared service install 生成的 Cloudflared
REM    服务（通常是另一条隧道），本脚本不会覆盖它。
REM =====================================================================

REM ---------- 可按需修改 ----------
set "MC_SVC=meshcentral.exe"
set "CF_SVC=CloudflaredDesk"
set "PORT=3000"
set "CF=C:\Program Files (x86)\cloudflared\cloudflared.exe"

REM 想强制指定 MeshCentral 位置就填这里；留空则自动探测
set "MC_DIR="

REM ---------- 自动提权 ----------
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo 需要管理员权限，正在请求提权，请在弹窗中点「是」...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

set "SYS=%SystemRoot%\System32\config\systemprofile\.cloudflared"
set "USR=%USERPROFILE%\.cloudflared"
set "SC=%SystemRoot%\System32\sc.exe"

REM ---------- 自动定位 MeshCentral 程序目录 ----------
REM 优先级：本脚本上一级的 app\ > 上一级本身 > C:\mesh
if not defined MC_DIR if exist "%~dp0..\app\node_modules\meshcentral" for %%i in ("%~dp0..\app") do set "MC_DIR=%%~fi"
if not defined MC_DIR if exist "%~dp0..\node_modules\meshcentral" for %%i in ("%~dp0..") do set "MC_DIR=%%~fi"
if not defined MC_DIR set "MC_DIR=C:\mesh"

echo.
echo ============ 开机自启固化 ============
echo   MeshCentral : !MC_DIR!
echo   服务名      : %MC_SVC% / %CF_SVC%
echo.

REM ---------- 环境检查 ----------
if not exist "%CF%" (
    echo [错误] 找不到 cloudflared: %CF%
    echo        请先运行: winget install --id Cloudflare.cloudflared
    echo        若装在别的位置，请修改本脚本顶部的 CF 变量。
    pause
    exit /b 1
)
if not exist "!MC_DIR!\node_modules\meshcentral" (
    echo [错误] !MC_DIR! 下没有 node_modules\meshcentral
    echo        请确认 MeshCentral 安装位置，或修改本脚本顶部的 MC_DIR。
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

echo   隧道 UUID   : !TID!
echo   凭据文件    : !CREDFILE!
echo   入口域名    : !HOST!
echo   监听端口    : %PORT%
echo.
pause

REM ---------- 1. 释放端口 ----------
echo [1/6] 释放 %PORT% 端口（只停 node 进程，避免误杀其他程序）
powershell -NoProfile -Command "Get-NetTCPConnection -LocalPort %PORT% -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique | ForEach-Object { $p = Get-Process -Id $_ -ErrorAction SilentlyContinue; if ($p -and $p.ProcessName -eq 'node') { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue } }"
timeout /t 3 /nobreak >nul

REM ---------- 2. MeshCentral 服务 ----------
echo [2/6] 注册并启动 MeshCentral 服务
net start "%MC_SVC%" >nul 2>&1
REM 判断服务是否注册过
"%SC%" query "%MC_SVC%" >nul 2>&1
if errorlevel 1 (
    echo       服务未注册，正在注册...
    pushd "!MC_DIR!"
    call node node_modules\meshcentral --install
    popd
    timeout /t 15 /nobreak >nul
) else (
    echo       服务已注册，校验指向路径...
    set "OLDPATH="
    for /f "tokens=2 delims==" %%p in ('wmic service where "name='%MC_SVC%'" get PathName /value 2^>nul') do set "OLDPATH=%%p"
    echo       当前: !OLDPATH!
    echo !OLDPATH! | findstr /i /c:"!MC_DIR!" >nul
    if errorlevel 1 (
        echo       指向已失效（程序目录搬迁过），移除旧注册...
        net stop "%MC_SVC%" >nul 2>&1
        timeout /t 4 /nobreak >nul
        "%SC%" delete "%MC_SVC%" >nul 2>&1
        timeout /t 4 /nobreak >nul
        pushd "!MC_DIR!"
        call node node_modules\meshcentral --install
        popd
        timeout /t 15 /nobreak >nul
    )
)
net start "%MC_SVC%" >nul 2>&1
timeout /t 20 /nobreak >nul

REM ---------- 3. 系统级配置目录 ----------
echo [3/6] 准备系统级配置目录
echo       %SYS%
if not exist "%SYS%" mkdir "%SYS%"
copy /Y "%USR%\!CREDFILE!" "%SYS%\!CREDFILE!" >nul
if exist "%USR%\cert.pem" copy /Y "%USR%\cert.pem" "%SYS%\cert.pem" >nul

REM cloudflared 服务以 LocalSystem 运行，读的是这个系统级目录下的配置，
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

REM ---------- 4. 创建独立服务 ----------
echo [4/6] 创建 cloudflared 服务 %CF_SVC%
echo       不使用 cloudflared service install，避免覆盖已有的
echo       Cloudflared 服务（那是另一条隧道）。
"%SC%" query "%CF_SVC%" >nul 2>&1
if not errorlevel 1 (
    net stop "%CF_SVC%" >nul 2>&1
    timeout /t 4 /nobreak >nul
    "%SC%" delete "%CF_SVC%" >nul 2>&1
    timeout /t 4 /nobreak >nul
)
"%SC%" create "%CF_SVC%" binPath= "\"%CF%\" --config=\"%SYS%\config.yml\" tunnel run" start= auto DisplayName= "Cloudflare Tunnel (desk)" >nul
if errorlevel 1 (
    echo [错误] 创建服务失败，请检查上面的报错
    pause
    exit /b 1
)
"%SC%" description "%CF_SVC%" "Cloudflare 命名隧道，为本机 MeshCentral 提供固定公网入口。" >nul
REM 崩溃后自动重启：5 秒 / 10 秒 / 30 秒，计数每天重置
"%SC%" failure "%CF_SVC%" reset= 86400 actions= restart/5000/restart/10000/restart/30000 >nul
echo       服务已创建

REM ---------- 5. 启动 ----------
echo [5/6] 启动服务
net start "%CF_SVC%"
timeout /t 8 /nobreak >nul

REM ---------- 6. 验证 ----------
echo [6/6] 状态确认
powershell -NoProfile -Command "Get-Service '%MC_SVC%','%CF_SVC%' | Format-Table Name,Status,StartType -AutoSize"
echo 本机服务探测：
powershell -NoProfile -Command "try { '  HTTP ' + (Invoke-WebRequest -Uri 'https://127.0.0.1:%PORT%/' -SkipCertificateCheck -TimeoutSec 8).StatusCode } catch { '  还没起来，等 30 秒后重开 https://127.0.0.1:%PORT% 看看' }" 2>nul
echo.
echo 固定访问地址: https://!HOST!
echo.
echo 两个服务均设为开机自启，以后不用再跑这个脚本。
echo 撤销请运行 uninstall-autostart.bat
echo.
pause
endlocal
