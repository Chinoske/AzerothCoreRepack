@echo off
setlocal
for %%i in ("%~dp0..") do set "ROOT=%%~fi\"
set "MYSQL_BIN=%ROOT%mysql\bin"
set "MYSQL_INI=%ROOT%mysql\my.ini"
set "MYSQL_DATA=%ROOT%mysql\data"
set "MYSQL_FLAG=%ROOT%mysql\acore_user.flag"

color 0C
echo.
echo  =============================================
echo   ATENCION: RESET DE BASES DE DATOS ACORE
echo  =============================================
echo.
echo  Se eliminaran las bases de datos:
echo    - acore_auth
echo    - acore_world
echo    - acore_characters
echo.
echo  MySQL y sus tablas de sistema se conservan.
echo  Esta accion NO se puede deshacer.
echo.
set /p "CONFIRM=  Escribe SI para confirmar: "
if /i not "%CONFIRM%"=="SI" (
    echo.
    echo  Cancelado.
    echo.
    pause
    exit /b 0
)

echo.
echo  [>] Deteniendo MySQL...
"%MYSQL_BIN%\mysqladmin.exe" "--defaults-file=%MYSQL_INI%" -u root --connect-timeout=2 shutdown >nul 2>&1
timeout /t 3 /nobreak >nul

echo  [>] Eliminando bases de datos...
for %%D in (acore_auth acore_world acore_characters) do (
    if exist "%MYSQL_DATA%\%%D" (
        rmdir /S /Q "%MYSQL_DATA%\%%D"
        echo  [+] %%D eliminada
    ) else (
        echo  [-] %%D no encontrada, omitida
    )
)

if exist "%MYSQL_FLAG%" (
    del /Q "%MYSQL_FLAG%"
    echo  [+] acore_user.flag eliminado
)

color 0A
echo.
echo  [OK] Reset completado.
echo.
echo  Al iniciar el servidor, WorldServer recreara
echo  las bases de datos automaticamente.
echo.
pause
