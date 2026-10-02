@echo off
chcp 65001 >nul
setlocal EnableDelayedExpansion

REM =====================================================================
REM  撤销开机自启：卸载 MeshCentral 服务和 cloudflared 服务
REM  只停服务、不删数据（账号库和配置都保留）
REM  用法：双击，UAC 点「是」
REM =====================================================================

set "MC_SVC=meshcentral.exe"
set "MC_DIR=C:\mesh"
set "CF=C:\Program Files (x86)\cloudflared\cloudflared.exe"

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo 需要管理员权限，正在请求提权...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo.
echo ============ 撤销开机自启 ============
echo.

echo [1/2] 停止并卸载 cloudflared 服务
net stop cloudflared >nul 2>&1
if exist "%CF%" (
    "%CF%" service uninstall
) else (
    echo       找不到 %CF%，跳过
)
timeout /t 3 /nobreak >nul

echo [2/2] 停止并卸载 MeshCentral 服务
net stop "%MC_SVC%" >nul 2>&1
timeout /t 3 /nobreak >nul
pushd "%MC_DIR%"
call node node_modules\meshcentral --uninstall
popd
timeout /t 3 /nobreak >nul

echo.
echo ============ 结果 ============
echo 服务已卸载。数据仍在 %MC_DIR%\meshcentral-data\ 里，没有被删除。
echo 想恢复自启，重新跑一次 setup-autostart.bat 即可。
echo.
pause
endlocal
