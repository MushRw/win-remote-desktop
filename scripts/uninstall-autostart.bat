@echo off
chcp 65001 >nul
setlocal EnableDelayedExpansion

REM =====================================================================
REM  撤销开机自启：卸载 MeshCentral 服务和 CloudflaredDesk 服务
REM
REM  只停服务、不删数据（账号库和配置都保留）
REM  用法：双击，UAC 点「是」
REM
REM  ⚠ 只删除本方案自己的 CloudflaredDesk 服务。
REM    不会执行 cloudflared service uninstall —— 那条命令会一并删掉
REM    cloudflared 自己安装的 Cloudflared 服务（可能是你在用的另一条隧道）。
REM =====================================================================

set "MC_SVC=meshcentral.exe"
set "CF_SVC=CloudflaredDesk"
set "MC_DIR="
set "SC=%SystemRoot%\System32\sc.exe"

REM ---------- 自动提权 ----------
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo 需要管理员权限，正在请求提权...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

REM ---------- 自动定位 MeshCentral 程序目录 ----------
if not defined MC_DIR if exist "%~dp0..\app\node_modules\meshcentral" for %%i in ("%~dp0..\app") do set "MC_DIR=%%~fi"
if not defined MC_DIR if exist "%~dp0..\node_modules\meshcentral" for %%i in ("%~dp0..") do set "MC_DIR=%%~fi"
if not defined MC_DIR set "MC_DIR=C:\mesh"

echo.
echo ============ 撤销开机自启 ============
echo.

echo [1/2] 停止并删除 %CF_SVC% 服务
net stop "%CF_SVC%" >nul 2>&1
timeout /t 4 /nobreak >nul
"%SC%" delete "%CF_SVC%" >nul 2>&1
if errorlevel 1 (
    echo       服务不存在，跳过
) else (
    echo       已删除
)
timeout /t 4 /nobreak >nul

echo [2/2] 停止并卸载 MeshCentral 服务
net stop "%MC_SVC%" >nul 2>&1
timeout /t 4 /nobreak >nul
if exist "!MC_DIR!\node_modules\meshcentral" (
    pushd "!MC_DIR!"
    call node node_modules\meshcentral --uninstall
    popd
) else (
    echo       找不到 !MC_DIR!\node_modules\meshcentral，改用 sc delete
    "%SC%" delete "%MC_SVC%" >nul 2>&1
)
timeout /t 4 /nobreak >nul

echo.
echo ============ 结果 ============
powershell -NoProfile -Command "Get-Service '%MC_SVC%','%CF_SVC%' -ErrorAction SilentlyContinue | Format-Table Name,Status -AutoSize" 2>nul
echo 服务已卸载。数据仍在 !MC_DIR!\meshcentral-data\ 里，没有被删除。
echo.
echo 若还想清理系统级隧道配置，手动删除这个目录：
echo   %SystemRoot%\System32\config\systemprofile\.cloudflared\
echo.
echo 想恢复自启，重新跑一次 setup-autostart.bat 即可。
echo.
pause
endlocal
