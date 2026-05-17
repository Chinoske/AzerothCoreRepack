# ⚔️ AzerothCore Repack — WotLK 3.3.5a

> 🏔️ Repack portable de [AzerothCore](https://github.com/azerothcore/azerothcore-wotlk) para Windows con todas las herramientas necesarias incluidas. No requiere instalaciones externas.

---

## 📦 Contenido

| Carpeta | Descripción |
|---------|-------------|
| ⚔️ `server/` | Binarios compilados (authserver, worldserver, dbimport) y configs |
| 🗄️ `mysql/` | MySQL 8.4 portable |
| 🔨 `cmake/` | CMake 4.3.2 portable |
| 📚 `boost/` | Boost 1.87.0 portable |
| 🌿 `git/` | Git portable |
| 📂 `source/` | Vacío — se llena al compilar |
| 🔧 `build/` | Vacío — se llena al compilar |
| 🛠️ `tools/` | Monitor, scripts de gestión |

---

## 🖥️ Requisitos

- 🪟 Windows 10 / 11 (64-bit)
- ⚙️ [Visual Studio 2022](https://visualstudio.microsoft.com/) con el módulo **Desarrollo para el escritorio con C++** *(solo necesario para compilar)*
- 🎮 Cliente de WoW **3.3.5a** *(lo provees tú)*

---

## 🚀 Primeros pasos

### 1️⃣ Clonar el repositorio

```
git clone https://github.com/Chinoske/AzerothCoreRepack.git
```

> 📎 **Requiere Git LFS.** Instálalo desde [git-lfs.com](https://git-lfs.com) y ejecuta `git lfs install` antes de clonar.

---

### 2️⃣ Abrir el Monitor

🖱️ Haz doble clic en **`Monitor.lnk`** en la raíz del repack.

---

### 3️⃣ Configuración inicial (primera vez)

Sigue los pasos numerados dentro del Monitor:

| Paso | Botón | Descripción |
|------|-------|-------------|
| 🔄 | **GitClone/Pull+Compilar** | Clona el código fuente y compila el servidor *(tarda 20-40 min)* |
| 1️⃣ | **Limpiar Base de Datos** | Elimina las DBs anteriores |
| 2️⃣ | **Importar Base de Datos** | Crea las 3 bases de datos del juego desde cero |
| 3️⃣ | **Crear Cuenta de Juego** | Crea tu cuenta de administrador |
| 4️⃣ | **Iniciar AuthServer** | Arranca el servidor de autenticación |
| 5️⃣ | **Iniciar WorldServer** | Arranca el servidor del mundo |

---

### 4️⃣ Configurar el cliente WoW

🗺️ Edita el `realmlist.wtf` de tu cliente WoW (botón **Realmlist** en el Monitor) y ponlo en:

```
set realmlist 127.0.0.1
```

---

## 🌟 Uso diario

Una vez configurado, solo necesitas:

1. 🖱️ Doble clic en **`Monitor.lnk`**
2. ▶️ Clic en **Iniciar Todo**

---

## 🔄 Mantener el servidor actualizado

Este repack está conectado directamente al repositorio oficial de AzerothCore. Cada vez que el equipo de AzerothCore lanza correcciones, mejoras o nuevo contenido, puedes actualizar tu servidor con un solo clic:

1. 🖱️ Abre el Monitor (`Monitor.lnk`)
2. 🔄 Presiona **GitClone/Pull+Compilar**

El Monitor descargará automáticamente los últimos cambios del [repositorio oficial de AzerothCore](https://github.com/azerothcore/azerothcore-wotlk) y recompilará el servidor con ellos. Los nuevos binarios quedan listos en `server/` y puedes iniciar el servidor normalmente.

> 💡 **No necesitas hacer nada más.** Reiniciar los servidores después de compilar aplica todos los cambios de base de datos automáticamente.

---

## 🗺️ Extractores de mapas

El servidor necesita los archivos de mapas de tu cliente WoW. En `tools/` encontrarás el script:

- 📜 `extract-data.bat` — extrae automáticamente maps, vmaps y mmaps desde tu cliente WoW

Copia tu carpeta de WoW 3.3.5a al equipo, ejecuta `extract-data.bat` y sigue las instrucciones.

---

## 📝 Notas

- 🔀 Las rutas se auto-configuran al lanzar el Monitor — el repack funciona desde cualquier carpeta o unidad.
- 👁️ `Monitor.vbs` está oculto intencionalmente; `Monitor.lnk` es el acceso directo a usar.
- 📦 El repositorio usa **Git LFS** para los binarios y herramientas portables (~3.2 GB).
