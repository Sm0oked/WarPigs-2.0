@echo off
rem WarPigs syntax checker - double-click after editing any .lua file.
rem Finds typos (missing quotes, commas, brackets) BEFORE you reload in-game.
rem See HOW-TO-EDIT.md for the editing guide.
setlocal

set "LUAC=C:\Users\PC\tools\lua54\luac54.exe"

if not exist "%LUAC%" (
    echo Could not find the Lua checker at:
    echo   %LUAC%
    echo.
    echo Syntax check skipped. You can still test your edit by reloading
    echo scripts in QQT and watching the console for a red error message.
    echo.
    pause
    exit /b 1
)

set ERR=0
for /r "%~dp0" %%f in (*.lua) do (
    "%LUAC%" -p "%%f" || set ERR=1
)

echo.
if "%ERR%"=="0" (
    echo   ALL FILES OK - safe to reload scripts in QQT.
) else (
    echo   A FILE HAS A TYPO - see the file name and line number above.
    echo   Fix it, or restore your .bak backup, then run this again.
)
echo.
pause
