@echo off
chcp 65001>nul
title 允许趴下：把枪械数据 can_crawl 改成 true（先备份）
echo 正在修改枪包数据……
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0allow_crawl_mdr308.ps1" %*
echo.
pause
