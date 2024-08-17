# ReSTIR DI in Falcor

This repository contains an implementation of [**ReSTIR DI** (Reservoir-based Spatio-Temporal Importance Resampling for Direct Illumination)](https://research.nvidia.com/publication/2020-07_spatiotemporal-reservoir-resampling-real-time-ray-tracing-dynamic-direct) within the **Falcor** rendering framework. The code forms the practical component of my master's thesis titled ["Efficient Sampling for Computing Complex Illumination in Real-Time"](https://dcgi.fel.cvut.cz/en/theses/2023/tomanka4/)

## Introduction

This project focuses on implementing the ReSTIR DI algorithm in Falcor, aiming to achieve efficient real-time sampling and rendering of complex illumination. ReSTIR offers a highly promising approach to efficiently computing direct illumination by leveraging spatio-temporal resampling techniques, making it suitable for real-time applications. The results demonstrate that ReSTIR is a highly effective approach for achieving high-quality real-time rendering while maintaining interactive performance. 

## Installation

Please refer to the **About Falcor** section below for details on installing the Falcor framework and other dependencies required to run this implementation.

## Implementation and Usage

The implementation is encapsulated as a separate render pass located in `\Source\RenderPasses\ReSTIRPass`. This pass can be integrated into the render graph for executing the ReSTIR DI algorithm.

### Running the Example Render Graph

An example render graph script that utilizes the ReSTIR pass is available in `Source\Mogwai\Data\ReSTIR.py`. To run this script:

1. **Open Mogwai:**
   Launch the Mogwai project from the Falcor framework.

2. **Load the Render Graph:**
   - Navigate to `File -> Load Script`.
   - Select the `ReSTIR.py` script from `Source\Mogwai\Data\ReSTIR.py`.

3. **Load a Scene:**
   - You can download scenes from resources such as [ORCA Rendering Resources](https://developer.nvidia.com/orca) (see the **About Falcor - Resources** section below).
   - Alternatively, use one of the test scenes available in `media\TestScenes`.

4. **Experiment with Settings:**
   - After loading the scene, the rendered output should be visible, along with the settings for individual render passes.
   - The settings for the ReSTIR pass are designed to be intuitive for those familiar with the algorithm. For further understanding, please refer to my thesis or consult related academic papers.
  
### Documentation

See [thesis](docs/thesis/thesis.pdf).

## Examples
![](docs/images/screenshot.PNG)
![](docs/images/restirdi_bistro.png)
![](docs/images/restirdi_zeroday.png)

# About Falcor

Falcor is a real-time rendering framework supporting DirectX 12. It aims to improve productivity of research and prototype projects.

## Prerequisites
- Windows 10 version 20H2 (October 2020 Update) or newer, OS build revision .789 or newer
- Visual Studio 2019 or 2022
- [Windows 10 SDK (10.0.19041.0) for Windows 10, version 2004](https://developer.microsoft.com/en-us/windows/downloads/windows-10-sdk/)
- A GPU which supports DirectX Raytracing, such as the NVIDIA Titan V or GeForce RTX
- NVIDIA driver 466.11 or newer

Optional:
- Windows 10 Graphics Tools. To run DirectX 12 applications with the debug layer enabled, you must install this. There are two ways to install it:
    - Click the Windows button and type `Optional Features`, in the window that opens click `Add a feature` and select `Graphics Tools`.
    - Download an offline package from [here](https://docs.microsoft.com/en-us/windows-hardware/test/hlk/windows-hardware-lab-kit#supplemental-content-for-graphics-media-and-mean-time-between-failures-mtbf-tests). Choose a ZIP file that matches the OS version you are using (not the SDK version used for building Falcor). The ZIP includes a document which explains how to install the graphics tools.
- NVAPI, CUDA, OptiX (see below)

## Building Falcor
Falcor uses the [CMake](https://cmake.org) build system. Additional information on how to use Falcor with CMake is available in the [CMake](docs/development/cmake.md) development documetation page.

### Visual Studio
If you are working with Visual Studio, you can setup a native Visual Studio solution by running `setup_vs2019.bat` (or `setup_vs2022.bat`, same process) after cloning this repository. The solution files are written to `build/windows-vs2019-d3d12` and the binary output is located in `build/windows-vs2019-d3d12/bin`.

By default, the solution is configured to use the native D3D12 rendering backend. Alternatively, you can setup additional solutions for the GFX backends by running `setup_vs2019.bat gfx-d3d12` or `setup_vs2019.bat gfx-vk`. Note that each configuration is setting up a separate build tree, so it's easy to switch between different backends during development.

### Visual Studio Code
If you are working with Visual Studio Code, run `setup.bat` after cloning this repository. This will setup a VS Code workspace in the `.vscode` folder with sensible defaults (only if `.vscode` does not exist yet). When opening the project folder in VS Code, it will prompt to install recommended extensions. We recommend you do, but at least make sure that _CMake Tools_ is installed. To build Falcor, you can select the configure preset by executing the _CMake: Select Configure Preset_ action (Ctrl+Shift+P). Choose the _Windows Ninja/MSVC D3D12_ preset (or one for a different rendering backend). Then simply hit _Build_ (or press F7) to build the project. The binary output is located in `build/windows-ninja-msvc-d3d12/bin`.

Warning: Do not start VS Code from _Git Bash_, it will modify the `PATH` environment variable to an incompatible format, leading to issues with CMake.

### Configure Presets
Falcor uses _CMake Presets_ store in `CMakePresets.json` to provide a set of commonly used build configurations. You can get the full list of available configure presets running `cmake --list-presets`:

```
$ cmake --list-presets
Available configure presets:

  "windows-vs2019-d3d12"         - Windows VS2019 D3D12
  "windows-vs2019-gfx-d3d12"     - Windows VS2019 GFX-D3D12
  "windows-vs2019-gfx-vk"        - Windows VS2019 GFX-VK
  "windows-vs2022-d3d12"         - Windows VS2022 D3D12
  "windows-vs2022-gfx-d3d12"     - Windows VS2022 GFX-D3D12
  "windows-vs2022-gfx-vk"        - Windows VS2022 GFX-VK
  "windows-ninja-msvc-d3d12"     - Windows Ninja/MSVC D3D12
  "windows-ninja-msvc-gfx-d3d12" - Windows Ninja/MSVC GFX-D3D12
  "windows-ninja-msvc-gfx-vk"    - Windows Ninja/MSVC GFX-VK
```

Use `cmake --preset <preset name>` to generate the build tree for a given preset. The build tree is written to the `build/<preset name>` folder and the binary output files are in `build/<preset name>/bin`.

An existing build tree can be compiled using `cmake --build build/<preset name>`.

Note: Some render passes (RTXGI, RTXDI, DLSS in particular) are not fully working with the new Slang GFX backend.

## Microsoft DirectX 12 Agility SDK
Falcor uses the [Microsoft DirectX 12 Agility SDK](https://devblogs.microsoft.com/directx/directx12agility/) to get access to the latest DirectX 12 features. Applications can enable the Agility SDK by putting `FALCOR_EXPORT_D3D12_AGILITY_SDK` in the main `.cpp` file. `Mogwai`, `FalcorTest` and `RenderGraphEditor` have the Agility SDK enabled by default.

## NVAPI
To enable NVAPI support, head over to https://developer.nvidia.com/nvapi and download the latest version of NVAPI (this build is tested against version R470).
Extract the content of the zip file into `external/packman/` and rename `R470-developer` to `nvapi`.

## CUDA
To enable CUDA support, download and install [CUDA 11.6.2](https://developer.nvidia.com/cuda-11-6-2-download-archive) or later and reconfigure the build.

See the `CudaInterop` sample application located in `Source/Samples/CudaInterop` for an example of how to use CUDA.

## OptiX
If you want to use Falcor's OptiX functionality (specifically the `OptixDenoiser` render pass) download the [OptiX SDK](https://developer.nvidia.com/designworks/optix/download) (Falcor is currently tested against OptiX version 7.3) After running the installer, link or copy the OptiX SDK folder into `external/packman/optix` (i.e., file `external/packman/optix/include/optix.h` should exist).

Note: You also need CUDA installed to compile the `OptixDenoiser` render pass, see above for details.

## NVIDIA RTX SDKs
Falcor ships with the following NVIDIA RTX SDKs:

- DLSS (https://github.com/NVIDIA/DLSS)
- RTXGI (https://github.com/NVIDIAGameWorks/RTXGI)
- RTXDI (https://github.com/NVIDIAGameWorks/RTXDI)
- NRD (https://github.com/NVIDIAGameWorks/RayTracingDenoiser)

Note that these SDKs are not under the same license as Falcor, see [LICENSE.md](LICENSE.md) for details.

## Falcor Configuration
`FalcorConfig.h` contains some flags which control Falcor's behavior.
- `FALCOR_ENABLE_LOGGER` - Enable/disable the logger. By default, it is set to `1`.
- `FALCOR_ENABLE_PROFILER` - Enable/disable the internal CPU/GPU profiler. By default, it is set to `1`.

## Resources
- [Falcor](https://github.com/NVIDIAGameWorks/Falcor): Falcor's GitHub page.
- [Documentation](./docs/index.md): Additional information and tutorials.
    - [Getting Started](./docs/getting-started.md)
    - [Render Graph Tutorials](./docs/tutorials/index.md)
- [Rendering Resources](https://benedikt-bitterli.me/resources) A collection of scenes loadable in Falcor (pbrt-v4 format).
- [ORCA](https://developer.nvidia.com/orca): A collection of scenes and assets optimized for Falcor.
