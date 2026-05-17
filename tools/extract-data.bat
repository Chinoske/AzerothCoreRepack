@echo off
setlocal enabledelayedexpansion
title AzerothCore - Extractor de Datos del Cliente
color 0A
call :main
echo.
pause
exit /b

:main
echo.
echo  =============================================
echo   AzerothCore - Extractor de Datos
echo   Cliente WoW 3.3.5a
echo  =============================================
echo.

for %%i in ("%~dp0..") do set "ROOT=%%~fi\"
set "SERVER=%ROOT%server"
set "DATA=%ROOT%data"

if not exist "%SERVER%\map_extractor.exe" (
    color 0C
    echo  [X] map_extractor.exe no encontrado en:
    echo      %SERVER%
    echo.
    echo      Ejecuta primero "Git Clone/Pull + Compilar"
    echo      en el Monitor y espera que termine.
    exit /b 1
)

set "WOW_DIR=C:\Wow"
echo  Directorio del cliente WoW 3.3.5a
echo  Presiona ENTER para usar: %WOW_DIR%
echo.
set /p "INPUT=  Ruta: "
if not "!INPUT!"=="" set "WOW_DIR=!INPUT!"
if "!WOW_DIR:~-1!"=="\" set "WOW_DIR=!WOW_DIR:~0,-1!"

if not exist "!WOW_DIR!\Data" (
    color 0C
    echo.
    echo  [X] No se encontro la carpeta "Data" en:
    echo      !WOW_DIR!
    echo.
    echo      Asegurate de que sea un cliente WoW 3.3.5a valido.
    exit /b 1
)

echo.
echo  [OK] Cliente: !WOW_DIR!
echo  [OK] Destino: %DATA%
echo.
echo  Presiona ENTER para comenzar la extraccion...
pause >nul

echo.
echo  [>] Copiando extractores...
copy /Y "%SERVER%\map_extractor.exe"   "!WOW_DIR!\" >nul 2>&1
copy /Y "%SERVER%\vmap4_extractor.exe" "!WOW_DIR!\" >nul 2>&1
copy /Y "%SERVER%\vmap4_assembler.exe" "!WOW_DIR!\" >nul 2>&1
copy /Y "%SERVER%\mmaps_generator.exe" "!WOW_DIR!\" >nul 2>&1
for %%f in ("%SERVER%\*.dll") do copy /Y "%%f" "!WOW_DIR!\" >nul 2>&1
echo  [+] Listo

echo.
echo  =============================================
echo   PASO 1/4 - DBC y Mapas  (~5-15 min)
echo  =============================================
echo.
cd /d "!WOW_DIR!"
map_extractor.exe
if !errorlevel! neq 0 (
    color 0C
    echo  [X] Error en map_extractor.exe
    call :cleanup "!WOW_DIR!"
    exit /b 1
)
echo  [+] DBC y Mapas extraidos

echo.
echo  =============================================
echo   PASO 2/4 - VMaps geometria  (~10-30 min)
echo  =============================================
echo.
vmap4_extractor.exe
if !errorlevel! neq 0 ( echo  [!] Advertencia en vmap4_extractor, continuando... )
echo  [+] Geometria extraida

echo.
echo  =============================================
echo   PASO 3/4 - Ensamblando VMaps  (~5-10 min)
echo  =============================================
echo.
if not exist "!WOW_DIR!\vmaps" mkdir "!WOW_DIR!\vmaps"
vmap4_assembler.exe Buildings vmaps
echo  [+] VMaps ensamblados

echo.
echo  =============================================
echo   PASO 4/4 - MMaps navegacion de NPCs
echo   AVISO: tarda entre 4 y 12 HORAS
echo  =============================================
echo.
set /p "MMAPS=  Generar MMaps ahora? (s/N): "
if /i not "!MMAPS!"=="s" goto :skip_mmaps

echo.
echo  [>] Generando MMaps... no cierres esta ventana
if not exist "!WOW_DIR!\mmaps" mkdir "!WOW_DIR!\mmaps"
echo mmapsConfig:> "!WOW_DIR!\mmaps-config.yaml"
echo   dataDir: "./">> "!WOW_DIR!\mmaps-config.yaml"
mmaps_generator.exe
del /Q "!WOW_DIR!\mmaps-config.yaml" >nul 2>&1
echo  [+] MMaps generados
goto :after_mmaps

:skip_mmaps
echo  [-] MMaps omitidos. Puedes ejecutar este bat de nuevo cuando quieras.

:after_mmaps

echo.
echo  =============================================
echo   Copiando datos a data\
echo  =============================================
cd /d "%ROOT%"
if exist "!WOW_DIR!\dbc"     xcopy /E /Y /I /Q "!WOW_DIR!\dbc"     "%DATA%\dbc\"     >nul && echo  [+] dbc\
if exist "!WOW_DIR!\maps"    xcopy /E /Y /I /Q "!WOW_DIR!\maps"    "%DATA%\maps\"    >nul && echo  [+] maps\
if exist "!WOW_DIR!\vmaps"   xcopy /E /Y /I /Q "!WOW_DIR!\vmaps"   "%DATA%\vmaps\"   >nul && echo  [+] vmaps\
if exist "!WOW_DIR!\mmaps"   xcopy /E /Y /I /Q "!WOW_DIR!\mmaps"   "%DATA%\mmaps\"   >nul && echo  [+] mmaps\
if exist "!WOW_DIR!\cameras" xcopy /E /Y /I /Q "!WOW_DIR!\cameras" "%DATA%\cameras\" >nul && echo  [+] cameras\

call :cleanup "!WOW_DIR!"
color 0A
echo.
echo  =============================================
echo   Extraccion completada - Datos en: %DATA%
echo  =============================================
echo.
echo  Siguiente paso: abre Monitor.bat e Iniciar Todo
exit /b 0

:cleanup
del /Q "%~1\map_extractor.exe"   >nul 2>&1
del /Q "%~1\vmap4_extractor.exe" >nul 2>&1
del /Q "%~1\vmap4_assembler.exe" >nul 2>&1
del /Q "%~1\mmaps_generator.exe" >nul 2>&1
exit /b 0
