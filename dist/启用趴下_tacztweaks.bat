@echo off
chcp 65001>nul
title 启用 TaCZ Tweaks 的趴下功能（crawl.enabled=true）
echo 正在修改 config\tacztweaks.json（先备份）……
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0enable_crawl_tacztweaks.ps1" %*
echo.
pause
