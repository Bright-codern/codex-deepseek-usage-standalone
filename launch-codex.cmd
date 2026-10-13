@echo off
chcp 65001 >nul
setlocal
set "DIR=%LOCALAPPDATA%\Programs\DeepSeekUsage"
rem 探针：第一行就写标记，用于确认脚本是否真的被执行
>>"%DIR%\launch-cmd.log" echo [%date% %time%] cmd 入口被触发
echo ============================================
echo  DeepSeek 消耗：正在以调试模式启动 Codex
echo  Codex 会先关闭再自动重开，请稍候（最长约 1 分钟）
echo  这个窗口会显示进度，不要关闭它
echo ============================================
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%DIR%\launch-codex.ps1" -Force
set RC=%ERRORLEVEL%
echo.
echo 脚本退出码: %RC%
echo 详细日志: %DIR%\launch.log
echo 窗口将在 15 秒后关闭
timeout /t 15 /nobreak >nul
endlocal
