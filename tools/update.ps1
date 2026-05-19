# AzerothCore Portable - Update & Compile
# Clona o actualiza el codigo fuente, compila y despliega a server\

$ROOT    = Split-Path $PSScriptRoot -Parent
$SRC     = "$ROOT\source"
$BUILD   = "$ROOT\build"
$SERVER  = "$ROOT\server"
$REPO    = "https://github.com/azerothcore/azerothcore-wotlk.git"
$MODREPO = "https://github.com/azerothcore/mod-ale.git"

function Write-H($msg)    { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }
function Write-OK($msg)   { Write-Host "  [+] $msg" -ForegroundColor Green }
function Write-Fail($msg) { Write-Host "  [X] $msg" -ForegroundColor Red }
function Write-Info($msg) { Write-Host "  [>] $msg" -ForegroundColor Gray }
function Write-Warn($msg) { Write-Host "  [!] $msg" -ForegroundColor Yellow }

Clear-Host
Write-Host ""
Write-Host "  AzerothCore Portable - Actualizar y Compilar" -ForegroundColor White
Write-Host "  Directorio: $ROOT" -ForegroundColor Gray
Write-Host ""

# ============================================================
# Detectar herramientas
# ============================================================

Write-H "Verificando herramientas"

$git = "$ROOT\git\cmd\git.exe"
if (Test-Path $git) { Write-OK "git: $git" } else { Write-Fail "git no encontrado en $ROOT\git"; Read-Host; exit 1 }

$cmake = "$ROOT\cmake\bin\cmake.exe"
if (Test-Path $cmake) { Write-OK "cmake: $cmake" } else { Write-Fail "cmake no encontrado en $ROOT\cmake"; Read-Host; exit 1 }

$majorMap = @{ 15="Visual Studio 15 2017"; 16="Visual Studio 16 2019"; 17="Visual Studio 17 2022"; 18="Visual Studio 18 2026" }
$vsInstances = @()

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (Test-Path $vswhere) {
    $vsJson = & $vswhere -all -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -format json 2>$null
    if ($vsJson) {
        try {
            foreach ($vs in ($vsJson | ConvertFrom-Json)) {
                $maj = [int](($vs.installationVersion -split '\.')[0])
                $gen = if ($majorMap.ContainsKey($maj)) { $majorMap[$maj] } else { "Visual Studio $maj" }
                $vsInstances += [PSCustomObject]@{
                    Name      = $vs.displayName
                    Path      = $vs.installationPath
                    Generator = $gen
                    MSBuild   = "$($vs.installationPath)\MSBuild\Current\Bin\MSBuild.exe"
                }
            }
        } catch {}
    }
}

if ($vsInstances.Count -eq 0) {
    $yearMap = @{ "2026"="Visual Studio 18 2026"; "2022"="Visual Studio 17 2022"; "2019"="Visual Studio 16 2019"; "2017"="Visual Studio 15 2017" }
    foreach ($year in @("2026","2022","2019","2017")) {
        foreach ($ed in @("Community","Professional","Enterprise","BuildTools")) {
            $p = "C:\Program Files\Microsoft Visual Studio\$year\$ed\MSBuild\Current\Bin\MSBuild.exe"
            if (Test-Path $p) {
                $vsInstances += [PSCustomObject]@{
                    Name      = "Visual Studio $year $ed"
                    Path      = "C:\Program Files\Microsoft Visual Studio\$year\$ed"
                    Generator = $yearMap[$year]
                    MSBuild   = $p
                }
            }
        }
    }
}

if ($vsInstances.Count -eq 0) {
    Write-Fail "No se encontro Visual Studio con C++ Desktop. Instala el workload 'Desarrollo de escritorio con C++'"
    Read-Host; exit 1
}

$selected = $null
# Preferir VS 17 (2022) sobre versiones preview más nuevas
$preferred = $vsInstances | Where-Object { $_.Generator -eq "Visual Studio 17 2022" } | Select-Object -First 1
if ($preferred) { $vsInstances = @($preferred) + ($vsInstances | Where-Object { $_.Generator -ne "Visual Studio 17 2022" }) }

if ($vsInstances.Count -eq 1) {
    $selected = $vsInstances[0]
    Write-OK "Visual Studio: $($selected.Name)"
} else {
    Write-Host ""
    Write-Host "  Versiones de Visual Studio encontradas:" -ForegroundColor White
    for ($i = 0; $i -lt $vsInstances.Count; $i++) {
        Write-Host ("  [{0}] {1}  ->  {2}" -f ($i + 1), $vsInstances[$i].Name, $vsInstances[$i].Generator) -ForegroundColor Cyan
    }
    Write-Host ""
    $choice = -1
    do {
        $raw = Read-Host "  Elige una version [1-$($vsInstances.Count)]"
        if ($raw -match '^\d+$') { $choice = [int]$raw - 1 }
    } while ($choice -lt 0 -or $choice -ge $vsInstances.Count)
    $selected = $vsInstances[$choice]
}

$msbuild     = $selected.MSBuild
$vsGenerator = $selected.Generator
Write-OK "Usando: $($selected.Name)  ->  $vsGenerator"

$boost = "$ROOT\boost"
if (Test-Path "$boost\boost\version.hpp") { Write-OK "Boost: $boost" } else { Write-Fail "Boost no encontrado en $ROOT\boost"; Read-Host; exit 1 }

$mysqlConn = "$ROOT\mysql"
if (Test-Path "$mysqlConn\lib\libmysql.lib") { Write-OK "MySQL Connector: $mysqlConn" } else { Write-Fail "MySQL connector no encontrado en $ROOT\mysql\lib"; Read-Host; exit 1 }

# ============================================================
# Git clone o pull
# ============================================================

$skipGit = $env:SKIP_GIT -eq "1"

# Guardar commits anteriores para el resumen final
$prevCommitAC  = if (Test-Path "$SRC\.git")                  { & $git -C $SRC rev-parse HEAD 2>&1 | Where-Object { $_ -notmatch '^$' } | Select-Object -First 1 } else { $null }
$prevCommitALE = if (Test-Path "$SRC\modules\mod-ale\.git") { & $git -C "$SRC\modules\mod-ale" rev-parse HEAD 2>&1 | Where-Object { $_ -notmatch '^$' } | Select-Object -First 1 } else { $null }

if ($skipGit) {
    Write-H "Codigo fuente (omitido - solo compilar)"
    if (-not (Test-Path "$SRC\.git")) { Write-Fail "No hay codigo fuente en $SRC. Ejecuta sin SKIP_GIT primero."; Read-Host; exit 1 }
} else {
    Write-H "Codigo fuente"

    if (-not (Test-Path "$SRC\.git") -or -not (Test-Path "$SRC\CMakeLists.txt")) {
        Write-Info "Clonando AzerothCore (puede tardar 5-15 minutos)..."
        if (Test-Path $SRC) { Remove-Item $SRC -Recurse -Force }
        & $git clone $REPO $SRC --depth=1 2>&1 | ForEach-Object { "$_" }
        if ($LASTEXITCODE -ne 0) { Write-Fail "Error clonando repositorio"; Read-Host; exit 1 }
        Write-OK "AzerothCore clonado"
    } else {
        Write-Info "Actualizando AzerothCore..."
        Push-Location $SRC
        & $git stash 2>&1 | Out-Null
        & $git pull --rebase 2>&1 | ForEach-Object { "$_" }
        if ($LASTEXITCODE -ne 0) { Write-Warn "git pull tuvo conflictos, continuando..." }
        & $git stash pop 2>&1 | Out-Null
        Pop-Location
        Write-OK "AzerothCore actualizado"
    }

    $modAle = "$SRC\modules\mod-ale"
    if (-not (Test-Path "$modAle\.git")) {
        Write-Info "Clonando mod-ale..."
        if (-not (Test-Path "$SRC\modules")) { New-Item -ItemType Directory "$SRC\modules" -Force | Out-Null }
        & $git clone $MODREPO $modAle --depth=1 2>&1 | ForEach-Object { "$_" }
        if ($LASTEXITCODE -ne 0) { Write-Warn "No se pudo clonar mod-ale, continuando sin el." }
        else { Write-OK "mod-ale clonado" }
    } else {
        Write-Info "Actualizando mod-ale..."
        Push-Location $modAle
        & $git stash 2>&1 | Out-Null
        & $git pull --rebase 2>&1 | ForEach-Object { "$_" }
        & $git stash pop 2>&1 | Out-Null
        Pop-Location
        Write-OK "mod-ale actualizado"
    }
}

# ============================================================
# CMake configure
# ============================================================

Write-H "CMake - Configurar"

if (-not (Test-Path $BUILD)) { New-Item -ItemType Directory $BUILD -Force | Out-Null }

# Limpiar cache de CMake si existe para evitar paths de compilador rancios
$cmakeCache = "$BUILD\CMakeCache.txt"
if (Test-Path $cmakeCache) {
    Write-Info "Limpiando CMakeCache.txt anterior..."
    Remove-Item $cmakeCache -Force
}

$cmakeArgs = @(
    "-S", $SRC,
    "-B", $BUILD,
    "-G", $vsGenerator,
    "-A", "x64",
    "-DCMAKE_GENERATOR_INSTANCE=$($selected.Path)",
    "-DCMAKE_BUILD_TYPE=Release",
    "-DCMAKE_INSTALL_PREFIX=$ROOT",
    "-DTOOLS_BUILD=all",
    "-DWITH_WARNINGS=0",
    "-DSCRIPTS=static"
)

if ($boost)     { $cmakeArgs += "-DBOOST_ROOT=$boost" }
if ($mysqlConn) { $cmakeArgs += "-DMYSQL_ROOT_DIR=$mysqlConn" }

Write-Info "Ejecutando CMake configure..."
& $cmake @cmakeArgs
if ($LASTEXITCODE -ne 0) { Write-Fail "CMake configure fallo"; Read-Host; exit 1 }
Write-OK "CMake configurado"

# ============================================================
# Build
# ============================================================

Write-H "Compilando (puede tardar 10-30 minutos)"

$cores    = (Get-CimInstance Win32_ComputerSystem).NumberOfLogicalProcessors
$totalRAM = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)

# VS 18 (2026) consume mas memoria por proceso cl.exe que VS 17.
# CL_MPCount=1: serializa la compilacion dentro de cada proyecto para evitar
# conflictos de PCH (CMAKE_PCH.PCH bloqueado por multiples CL.exe en paralelo).
# Los proyectos siguen compilandose en paralelo entre si via --parallel.
$maxProjects = [math]::Max(1, [math]::Min($cores, [int]($totalRAM / 2)))
Write-Info "RAM: ${totalRAM} GB  |  Proyectos paralelos: $maxProjects  |  CL_MPCount: 1 (serializado por PCH)"

# Limpiar procesos cl.exe colgados de compilaciones anteriores fallidas
$clProcs = Get-Process "cl" -ErrorAction SilentlyContinue
if ($clProcs) {
    Write-Warn "Terminando $($clProcs.Count) proceso(s) cl.exe colgado(s)..."
    $clProcs | Stop-Process -Force
    Start-Sleep -Milliseconds 500
}

# Borrar PCH corruptos/bloqueados del build anterior
$stale = Get-ChildItem $BUILD -Recurse -Filter "*.pch" -ErrorAction SilentlyContinue
if ($stale) {
    Write-Info "Borrando $($stale.Count) PCH(s) del build anterior..."
    $stale | Remove-Item -Force -ErrorAction SilentlyContinue
}

& $cmake --build $BUILD --config Release --parallel $maxProjects -- /p:CL_MPCount=1
if ($LASTEXITCODE -ne 0) { Write-Fail "La compilacion fallo. Revisa los errores arriba."; Read-Host; exit 1 }
Write-OK "Compilacion exitosa"

# ============================================================
# Deploy a server\
# ============================================================

Write-H "Desplegando binarios a server\"

$binRelease = "$BUILD\bin\Release"
if (-not (Test-Path $binRelease)) { Write-Fail "No se encontro $binRelease"; Read-Host; exit 1 }

foreach ($e in @("authserver.exe","worldserver.exe","dbimport.exe","map_extractor.exe","vmap4_extractor.exe","vmap4_assembler.exe","mmaps_generator.exe")) {
    if (Test-Path "$binRelease\$e") {
        Copy-Item "$binRelease\$e" "$SERVER\$e" -Force
        Write-OK $e
    }
}

# Copiar TODAS las DLLs desde build\bin\Release (si existen)
$dllFiles = Get-ChildItem "$binRelease\*.dll" -ErrorAction SilentlyContinue
if ($dllFiles) {
    foreach ($dll in $dllFiles) {
        Copy-Item $dll.FullName "$SERVER\$($dll.Name)" -Force
    }
    Write-OK "DLLs desde build\bin\Release ($($dllFiles.Count) archivos)"
} else {
    Write-Warn "No se encontraron DLLs en $binRelease"
}

# ============================================================
# Copiar DLLs específicas desde ubicaciones concretas
# ============================================================
Write-H "Buscando DLLs adicionales en el sistema"

# Lista de DLLs a buscar y copiar
$requiredDlls = @("libmysql.dll", "libcrypto-3-x64.dll", "libssl-3-x64.dll", "legacy.dll")

# Definir rutas exactas para cada DLL
$searchPaths = @(
    @{ Name="libmysql.dll";       Paths=@("$ROOT\mysql\lib", "$ROOT\server") },
    @{ Name="libcrypto-3-x64.dll"; Paths=@("$ROOT\server") },
    @{ Name="libssl-3-x64.dll";    Paths=@("$ROOT\server") },
    @{ Name="legacy.dll";          Paths=@("$ROOT\server") }
)

# Función para buscar un archivo en múltiples rutas
function Find-DllFile {
    param([string]$fileName, $searchPathsList)
    
    # 1. Buscar en rutas específicas
    foreach ($search in $searchPathsList) {
        if ($search.Name -eq $fileName) {
            foreach ($path in $search.Paths) {
                $fullPath = Join-Path $path $fileName
                if (Test-Path $fullPath) {
                    return $fullPath
                }
            }
        }
    }
    
    # 2. Buscar en System32 y SysWOW64 (ubicaciones comunes del sistema)
    $systemPaths = @(
        "$env:windir\System32\$fileName",
        "$env:windir\SysWOW64\$fileName"
    )
    foreach ($sysPath in $systemPaths) {
        if (Test-Path $sysPath) {
            return $sysPath
        }
    }
    
    return $null
}

# Buscar y copiar cada DLL
foreach ($dllName in $requiredDlls) {
    $foundPath = Find-DllFile -fileName $dllName -searchPathsList $searchPaths
    $destPath  = "$SERVER\$dllName"

    if ($foundPath) {
        $srcResolved  = (Resolve-Path $foundPath -ErrorAction SilentlyContinue)?.Path
        $dstResolved  = (Resolve-Path $destPath  -ErrorAction SilentlyContinue)?.Path
        if ($srcResolved -and $dstResolved -and ($srcResolved -eq $dstResolved)) {
            Write-OK "$dllName ya esta en $SERVER"
        } else {
            Copy-Item $foundPath $destPath -Force
            Write-OK "$dllName copiada desde $foundPath"
        }
    } else {
        Write-Warn "No se encontro $dllName. Colócala manualmente en $SERVER"
    }
}

$cfgDest = "$SERVER\configs"
foreach ($f in @("authserver.conf","worldserver.conf","dbimport.conf")) {
    $cfgSrc2 = "$binRelease\configs\$f"
    if (-not (Test-Path "$cfgDest\$f") -and (Test-Path $cfgSrc2)) {
        Copy-Item $cfgSrc2 "$cfgDest\$f" -Force
        Write-OK "configs\$f (nuevo)"
    }
}

if (-not (Test-Path "$cfgDest\modules")) { New-Item -ItemType Directory "$cfgDest\modules" -Force | Out-Null }
$modCfgSrc = "$binRelease\configs\modules\mod_ale.conf"
if (-not (Test-Path "$cfgDest\modules\mod_ale.conf") -and (Test-Path $modCfgSrc)) {
    Copy-Item $modCfgSrc "$cfgDest\modules\mod_ale.conf" -Force
    Write-OK "configs\modules\mod_ale.conf (nuevo)"
}

$luaSrc = "$binRelease\lua_scripts"
$luaDst = "$SERVER\lua_scripts"
if (Test-Path $luaSrc) {
    if (-not (Test-Path $luaDst)) { New-Item -ItemType Directory $luaDst -Force | Out-Null }
    Get-ChildItem $luaSrc | Where-Object { -not (Test-Path "$luaDst\$($_.Name)") } | ForEach-Object {
        Copy-Item $_.FullName "$luaDst\$($_.Name)" -Force
        Write-OK "lua_scripts\$($_.Name) (nuevo)"
    }
}

# ============================================================
# Actualizar bases de datos (dbimport)
# ============================================================

Write-H "Actualizando bases de datos"

$dbimport = "$SERVER\dbimport.exe"
$dbCfg    = "$SERVER\configs\dbimport.conf"

if (-not (Test-Path $dbimport)) {
    Write-Warn "dbimport.exe no encontrado en $SERVER — saltando actualizacion de DB"
} elseif (-not (Test-Path $dbCfg)) {
    Write-Warn "dbimport.conf no encontrado en $dbCfg — saltando actualizacion de DB"
} else {
    Write-Info "Ejecutando dbimport (puede tardar 1-5 minutos en la primera vez)..."

    # Capturar salida para mostrar resumen
    $dbOut = & $dbimport --config $dbCfg 2>&1
    $dbExit = $LASTEXITCODE

    # Filtrar lineas relevantes: tablas actualizadas, errores, advertencias
    $applied  = @($dbOut | Where-Object { $_ -match 'Appli|updat|import|Query OK|success' -and $_ -notmatch '^$' })
    $dbErrors = @($dbOut | Where-Object { $_ -match 'ERROR|error|FAILED|fail' })
    $dbWarns  = @($dbOut | Where-Object { $_ -match 'Warning|warn|skip' })

    if ($dbExit -eq 0) {
        Write-OK "Base de datos actualizada correctamente"
    } else {
        Write-Warn "dbimport termino con codigo $dbExit (puede ser normal si no hay updates pendientes)"
    }

    if ($applied.Count -gt 0) {
        Write-Host ""
        Write-Host "  Archivos SQL aplicados: $($applied.Count)" -ForegroundColor Green
        $applied | Select-Object -First 20 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGreen }
        if ($applied.Count -gt 20) { Write-Host "    ... y $($applied.Count - 20) mas" -ForegroundColor DarkGray }
    } else {
        Write-Info "Sin updates pendientes o ya aplicados previamente"
    }

    if ($dbErrors.Count -gt 0) {
        Write-Host ""
        Write-Host "  Errores DB ($($dbErrors.Count)):" -ForegroundColor Red
        $dbErrors | ForEach-Object { Write-Host "    $_" -ForegroundColor Red }
    }

    if ($dbWarns.Count -gt 0) {
        Write-Host "  Advertencias DB ($($dbWarns.Count)):" -ForegroundColor Yellow
        $dbWarns | Select-Object -First 10 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkYellow }
    }
}

Write-Host ""
Write-Host "  =============================================" -ForegroundColor Cyan
Write-Host "   Actualizacion y compilacion completada" -ForegroundColor Green
Write-Host "  =============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Binarios desplegados en: $SERVER" -ForegroundColor Gray
Write-Host ""

# ============================================================
# Resumen categorizado de commits nuevos
# ============================================================

function Get-NewCommits($repoPath, $prevHash) {
    if (-not $prevHash -or -not (Test-Path "$repoPath\.git")) { return @() }
    $msgs = & $git -C $repoPath log "$prevHash..HEAD" --format="%s" 2>$null
    if (-not $msgs) { return @() }
    return @($msgs)
}

$cats = [ordered]@{
    "COMBATE / SPELLS"     = @{ Icon="[SPL]"; Color="Red";     Keys=@("spell","aura","cast","cooldown","damage","heal","proc","mana","combat","talent","rune","buff","debuff","dispel","interrupt","stun","fear","charm","resist","immuniti") }
    "CRIATURAS / IA"       = @{ Icon="[NPC]"; Color="Yellow";  Keys=@("creature","npc","ai","smartai","waypoint","boss","summon","pet","escort","gossip","vendor","trainer","loot","taming") }
    "JUGADOR"              = @{ Icon="[PLR]"; Color="Green";   Keys=@("player","character","char","inventory","item","equip","bag","bank","mail","auction","talent","skill","level","xp","honor","arena","rating","bg","battleground","pvp","duel","resurrect","death","corpse") }
    "MISIONES / LOGROS"    = @{ Icon="[QST]"; Color="Cyan";    Keys=@("quest","achievement","criteria","reputation","faction","reward","objective","breadcrumb") }
    "MUNDO / MAPAS"        = @{ Icon="[MAP]"; Color="Blue";    Keys=@("world","map","area","zone","terrain","gameobject","transport","vehicle","spawn","position","phase","pool","weather","fishing","gathering","herb","mine","chest") }
    "INSTANCIAS / RAIDS"   = @{ Icon="[INS]"; Color="Magenta"; Keys=@("instance","dungeon","raid","lfg","encounter","reset","lockout","heroic","normal","script") }
    "CONSOLA / GM"         = @{ Icon="[CMD]"; Color="White";   Keys=@("command","gm","console","cheat","warden","account","ban","kick","mute","announce","ticket") }
    "BASE DE DATOS"        = @{ Icon="[DB] "; Color="DarkYellow"; Keys=@("db","sql","database","migration","data","table","column","fix data","worlddb","update sql") }
    "SERVIDOR / RED"       = @{ Icon="[SRV]"; Color="DarkCyan"; Keys=@("server","auth","socket","session","opcode","packet","network","config","crash","performance","memory","thread","mutex","core") }
    "MODULO LUA / ALE"     = @{ Icon="[LUA]"; Color="DarkGreen"; Keys=@("lua","ale","mod-ale","eluna","script","hook","api","module") }
    "OTROS / GENERAL"      = @{ Icon="[---]"; Color="Gray";    Keys=@() }
}

function Categorize-Commit($msg) {
    $ml = $msg.ToLower()
    foreach ($cat in $cats.Keys) {
        if ($cats[$cat].Keys.Count -eq 0) { continue }
        foreach ($kw in $cats[$cat].Keys) {
            if ($ml -match [regex]::Escape($kw)) { return $cat }
        }
    }
    return "OTROS / GENERAL"
}

$allCommits = @{}
foreach ($cat in $cats.Keys) { $allCommits[$cat] = @() }

$newAC  = Get-NewCommits $SRC $prevCommitAC
$newALE = Get-NewCommits "$SRC\modules\mod-ale" $prevCommitALE

foreach ($msg in $newAC)  { $c = Categorize-Commit $msg; $allCommits[$c] += "  $msg" }
foreach ($msg in $newALE) { $c = Categorize-Commit $msg; $allCommits[$c] += "  [mod-ale] $msg" }

$total = ($newAC.Count + $newALE.Count)

if ($total -eq 0) {
    Write-Host "  Sin commits nuevos en esta actualizacion." -ForegroundColor Gray
} else {
    Write-Host "  +-------------------------------------------------+" -ForegroundColor Cyan
    Write-Host ("  |   RESUMEN DE CAMBIOS — {0,3} commit(s) nuevos    |" -f $total) -ForegroundColor Cyan
    Write-Host "  +-------------------------------------------------+" -ForegroundColor Cyan
    Write-Host ""

    foreach ($cat in $cats.Keys) {
        $items = $allCommits[$cat]
        if ($items.Count -eq 0) { continue }
        $ico   = $cats[$cat].Icon
        $col   = $cats[$cat].Color
        Write-Host ("  {0} {1} ({2})" -f $ico, $cat, $items.Count) -ForegroundColor $col
        foreach ($line in $items) {
            # Truncar a 90 chars para que quepa en consola
            $display = if ($line.Length -gt 90) { $line.Substring(0,87) + "..." } else { $line }
            Write-Host "      $display" -ForegroundColor DarkGray
        }
        Write-Host ""
    }
}

Read-Host "  Presiona ENTER para cerrar"