@echo off
rem Offline Gradle launcher for this project.
rem Uses the project-local Gradle user home so the build never writes outside the workspace.
setlocal
set "GRADLE_USER_HOME=%~dp0.gradle-home"
call "%~dp0gradlew.bat" --offline --console=plain %*
endlocal
