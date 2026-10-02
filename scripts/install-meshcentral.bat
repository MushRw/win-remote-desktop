@echo off
chcp 65001 >nul
setlocal EnableDelayedExpansion

REM =====================================================================
REM  部署脚本：安装 MeshCentral 并预建一个本地账号
REM  对应 README「一、部署」的第 3 ~ 6 步
REM  用法：双击运行，不需要管理员权限
REM  注意：不要用 npm install -g。MeshCentral 官方明确说明全局安装会让
REM        Windows 服务注册失效（服务会秒退）。必须装在本地目录。
REM =====================================================================

REM ---------- 可按需修改 ----------
set "PORT=3000"
set "CERTNAME=desk.example.com"

REM MeshCentral 安装位置。留空则自动探测，优先级：
REM   本脚本上一级的 app\  >  上一级本身  >  C:\mesh
set "APP="
if not defined APP if exist "%~dp0..\app" for %%i in ("%~dp0..\app") do set "APP=%%~fi"
if not defined APP if exist "%~dp0..\package.json" for %%i in ("%~dp0..") do set "APP=%%~fi"
if not defined APP set "APP=C:\mesh"

REM ---------- 环境检查 ----------
where node >nul 2>&1
if errorlevel 1 (
    echo [错误] 没找到 node。请先安装 Node.js LTS: https://nodejs.org/
    pause
    exit /b 1
)
where npm >nul 2>&1
if errorlevel 1 (
    echo [错误] 没找到 npm。请重新安装 Node.js LTS。
    pause
    exit /b 1
)

echo.
echo ============ MeshCentral 部署 ============
echo   安装目录 : %APP%
echo   监听端口 : %PORT%
echo   证书名   : %CERTNAME%
echo   （证书名必须是「带点号」的域名形式，否则 MeshCentral 会自动
echo     降级成 LAN-only 模式，并丢掉默认 STUN 服务器）
echo.
pause

REM ---------- 1. 初始化 ----------
echo [1/5] 准备目录
if not exist "%APP%" mkdir "%APP%"
cd /d "%APP%"
if not exist package.json (
    call npm init -y >nul
    echo       package.json 已创建
) else (
    echo       package.json 已存在，跳过
)

REM ---------- 2. 安装本体 ----------
echo [2/5] 安装 meshcentral（首次约 1~2 分钟）
if exist node_modules\meshcentral (
    echo       已安装，跳过。要升级请执行: npm update meshcentral
) else (
    call npm install meshcentral
    if errorlevel 1 (
        echo [错误] 安装失败，请检查网络。
        pause
        exit /b 1
    )
)

REM ---------- 3. 生成数据目录与自签证书 ----------
echo [3/5] 首次运行，生成 meshcentral-data 与自签证书
start /b "" node node_modules\meshcentral --port %PORT%
timeout /t 12 /nobreak >nul
powershell -NoProfile -Command "Get-NetTCPConnection -LocalPort %PORT% -State Listen -ErrorAction SilentlyContinue | Select-Object -ExpandProperty OwningProcess -Unique | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }"
timeout /t 2 /nobreak >nul

if exist "%APP%\meshcentral-data\config.json" (
    echo       config.json 已生成
) else (
    echo [警告] 没有生成 config.json，请检查上面的报错
)

REM ---------- 4. 写入配置模板 ----------
echo [4/5] 写入配置文件
if exist "%APP%\meshcentral-data\config.json.orig" (
    echo       检测到 .orig 备份，说明已部署过，本次不覆盖 config.json
) else (
    if exist "%APP%\meshcentral-data\config.json" (
        copy /Y "%APP%\meshcentral-data\config.json" "%APP%\meshcentral-data\config.json.orig" >nul
    )
    powershell -NoProfile -Command "$p = '%~dp0..\config\meshcentral-config.example.json'; $t = Get-Content -Raw -LiteralPath $p; $t = $t.Replace('desk.example.com', '%CERTNAME%'); Set-Content -LiteralPath '%APP%\meshcentral-data\config.json' -Value $t -Encoding UTF8"
    echo       config.json 已按模板写入（含禁注册 / 免二次验证 / 关闭 IP 校验）
)

REM ---------- 5. 预建账号 ----------
echo [5/5] 预建本地账号
echo.
set "MCUSER="
set /p "MCUSER=  请输入用户名（不要用 admin / home 这类常见名）: "
if not defined MCUSER (
    echo       已跳过建账号。之后可手动执行:
    echo         node node_modules\meshcentral --createaccount ^<用户名^> --pass ^<密码^> --domain ""
    goto :done
)

echo   请输入密码（输入时不回显，至少 8 位）
for /f "usebackq delims=" %%p in (`powershell -NoProfile -Command "$s = Read-Host -AsSecureString; [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($s))"`) do set "MCPASS=%%p"
if not defined MCPASS (
    echo       密码为空，已跳过建账号。
    goto :done
)

node node_modules\meshcentral --createaccount %MCUSER% --pass "%MCPASS%" --domain ""
if errorlevel 1 (
    echo [警告] 建账号失败，可能该用户名已存在。
    echo        重置密码请执行: node node_modules\meshcentral --resetaccount %MCUSER% --pass ^<新密码^> --domain ""
) else (
    node node_modules\meshcentral --adminaccount %MCUSER% --domain ""
    echo       账号 %MCUSER% 已创建并提升为站点管理员
)
set "MCPASS="

:done
echo.
echo ============ 下一步 ============
echo   1. 按 README 第 7 步创建 Cloudflare 命名隧道
echo   2. 按 README 第 8 步写 %USERPROFILE%\.cloudflared\config.yml
echo   3. 双击 scripts\start-tunnel.bat 验证
echo   4. 验证通过后双击 scripts\setup-autostart.bat 固化开机自启
echo.
pause
endlocal
