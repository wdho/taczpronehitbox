@echo off
chcp 65001>nul
title 安装 TaCZ Prone Hitbox + Seamless Sprint（分离版）
echo 正在安装分离版（趴下命中箱 / 疾跑锁定），请稍候……
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install_to_instance.ps1" %*
echo.
pause
