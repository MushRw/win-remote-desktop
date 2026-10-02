@echo off
chcp 65001 >nul
setlocal

REM =====================================================================
REM  手动前台启动 Cloudflare 命名隧道（调试用，关掉窗口即断开）
REM  日常使用请双击 setup-autostart.bat 固化开机自启，之后不用管这个文件
REM =====================================================================

REM ---------- 改成你的隧道名（cloudflared tunnel create 时取的名字） ----------
set "TUNNEL=desk"

REM ---------- 如果本机有代理，会把 cloudflared 的 API 调用拦掉 ----------
REM 遇到 context deadline exceeded 时，把下面四行的 REM 去掉再试：
REM set "http_proxy="
REM set "https_proxy="
REM set "HTTP_PROXY="
REM set "HTTPS_PROXY="

where cloudflared >nul 2>&1
if errorlevel 1 (
    echo [错误] 没找到 cloudflared。请先运行:
    echo        winget install --id Cloudflare.cloudflared
    pause
    exit /b 1
)

echo.
echo ============ 启动命名隧道 ============
echo   隧道名 : %TUNNEL%
echo   配置   : %USERPROFILE%\.cloudflared\config.yml
echo.
echo   提示：本机 MeshCentral 必须先运行（net start meshcentral.exe），
echo         否则隧道能连上但页面会报 502。
echo.
echo   按 Ctrl+C 停止
echo.

cloudflared tunnel run %TUNNEL%

echo.
echo 隧道已退出。
pause
endlocal
