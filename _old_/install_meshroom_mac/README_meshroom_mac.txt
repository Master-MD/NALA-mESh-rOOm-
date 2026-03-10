Meshroom on Apple Silicon (M1–M4)
=================================
- CUDA translation to Apple Metal is not available. This installer builds CPU/OpenMP AliceVision + Qt6 Meshroom.
- Optional experimental OpenCL via MeshroomCL and VulkanSift helper.
- Optional AI upscalers (Real-ESRGAN / waifu2x via ncnn+MoltenVK).
- .app bundle is created and symlinked into ~/Applications.

Quickstart:
  chmod +x install_meshroom_pro_mac.sh
  ./install_meshroom_pro_mac.sh --ai-extras --experimental-opencl

Launch:
  ~/meshroom-local/Meshroom.app
  or
  ~/meshroom-local/bin/meshroom

Bambu 3MF:
  Use obj2threeMF to wrap OBJ/STL into a basic 3MF (geometry-only).
