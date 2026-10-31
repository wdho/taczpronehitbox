@echo off
chcp 65001>nul
title 允许趴下侧头（GD656Peek）
echo 正在修改当前存档的 gd656peek-server.toml（先备份）……
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0enable_prone_peek.ps1" %*
echo.
pause
