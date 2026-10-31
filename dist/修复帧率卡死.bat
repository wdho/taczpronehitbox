@echo off
chcp 65001>nul
title 修复无限制帧率导致整屏卡死（改 options.txt）
echo 正在修复：开启垂直同步 + 限制最大帧率 144……
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0fix_fps_freeze.ps1" %*
echo.
pause
