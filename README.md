<div align="center">
  <h1>NALA-mESh(rOOm) Ultimate</h1>
  <h3>Hybrid Local/Remote Photogrammetry for ComfyUI macOS</h3>
</div>

**NALA-mESh(rOOm)** is an advanced hybrid photogrammetry pipeline tailored for Apple Silicon (M1/M2/M3/M4) devices. Originating as an adaptation of the [AliceVision Meshroom](https://github.com/alicevision/Meshroom) framework, this project introduces the **Ultimate Hybrid** logic, bridging the gap between blazing-fast native macOS computing and powerful distributed NVIDIA rendering, all accessible via a custom [ComfyUI](https://github.com/comfyanonymous/ComfyUI) bridging node.

---

## Architecture: The Best of Both Worlds
Instead of forcefully rewriting the entire legacy C++ Meshroom environment (CUDA/AliceVision), this project leverages the most optimal rendering engine for the hardware. 

The custom `MeshroomRun` ComfyUI Node now routes to one of three engines:
1. 🍏 **Apple Native Engine (RealityKit / Metal):** A pure Swift command-line engine utilizing Apple's native **Object Capture API**. Highly optimized for Apple Silicon GPUs (M4 Max & Neural Engine), rendering 3D models fully locally in seconds without any Meshroom overhead.
2. 💻 **Local Meshroom (CPU Fallback/AliceVision):** Triggers the classic Meshroom CLI processing directly on your Mac, including a new `Headless Mode` for background invisible rendering.
3. ⚡️ **Remote Meshroom (NVIDIA Worker):** Automatically triggers via SSH and network a remote node (e.g., Ubuntu/Windows PC with massive NVIDIA GPUs) to crunch complex datasets using traditional AliceVision node graphs.

![Architecture](/Users/ultramacuser/.gemini/antigravity/brain/6036eefd-15f2-4490-afad-7102be196453/nala_meshroom_hybrid_architecture_1773148742262.png)

## Installation Guide
Simply run the installer on your macOS device:
`./meshroom_pro_comfy_installer.sh`

**The installer will automatically:**
- Setup the Python environments and ComfyUI folders.
- Compile the Swift native code (`meshroom_mac_native`) using `swiftc`.
- Inject the custom ComfyUI Nodes.

### Legal Attribution
*This project utilizes and interacts with concepts/binaries from AliceVision/Meshroom. All original Meshroom copyrights remain with the AliceVision contributors. The Meshroom-related scripts in this repository are subject to the [Mozilla Public License Version 2.0 (MPL-2.0)](https://www.mozilla.org/en-US/MPL/2.0/). This project is an independent wrapper and not officially endorsed by the AliceVision Association.*

<br><hr><br>

<div align="center">
  <h3>🇩🇪 DEUTSCHE BESCHREIBUNG</h3>
</div>

**NALA-mESh(rOOm)** ist eine hochentwickelte, hybride Photogrammetrie-Pipeline, die speziell für Apple Silicon (M1/M2/M3/M4) Geräte maßgeschneidert wurde. Ursprünglich als Anpassung für [AliceVision Meshroom](https://github.com/alicevision/Meshroom) gedacht, führt dieses Projekt die **Ultimate Hybrid** Logik ein: Es schließt die Lücke zwischen rasend schnellem nativen macOS-Computing und leistungsstarkem verteiltem NVIDIA-Rendering – alles zugänglich über einen eigens entwickelten [ComfyUI](https://github.com/comfyanonymous/ComfyUI) Bridge-Node.

## Architektur: Das Beste aus beiden Welten
Anstatt die riesige, veraltete C++ Meshroom-Umgebung (CUDA/AliceVision) krampfhaft für Apple neu zu schreiben, nutzt dieses Projekt die jeweils optimalste Render-Engine für die vorhandene Hardware.

Der Custom `MeshroomRun` ComfyUI Node steuert nun eine von drei Engines an:
1. 🍏 **Apple Native Engine (RealityKit / Metal):** Eine reine Swift-Kommandozeilen-Engine, die Apples native **Object Capture API** nutzt. Extrem optimiert für Apple Silicon GPUs (z.B. den M4 Max). Berechnet 3D-Modelle in Sekundenbruchteilen vollständig lokal – komplett ohne den riesigen Meshroom-Overhead.
2. 💻 **Local Meshroom (CPU Fallback/AliceVision):** Startet das klassische Meshroom direkt auf deinem Mac inkl. eines neuen `Headless Mode` für unsichtbares Rendering im Hintergrund.
3. ⚡️ **Remote Meshroom (NVIDIA Worker):** Löst vollautomatisch via SSH und Netzwerk einen entfernten Rechner aus (z.B. Ubuntu/Windows-PC mit schweren NVIDIA-Karten), um hochkomplexe Datensätze auf den dortigen AliceVision-Node-Graphen berechnen zu lassen.

## Installation
Führe einfach den Installer auf deinem macOS-Gerät aus:
`./meshroom_pro_comfy_installer.sh`

**Der Installer führt automatisch folgende Schritte aus:**
- Einrichten der Python-Umgebungen und ComfyUI Ordner.
- Kompilieren des nativen Swift-Codes (`meshroom_mac_native`) über den Mac Compiler `swiftc`.
- Injizieren der Custom ComfyUI Nodes in das UI.
