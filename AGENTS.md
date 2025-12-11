# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Phosphor is a macOS shader editor inspired by twigl.app that allows real-time editing and compilation of Metal shaders. It provides a split-view interface with a shader preview on the left and code editor on the right.

## Build & Run

This is an Xcode project targeting macOS 15.6+:
- Open `Phosphor.xcodeproj` in Xcode
- Build and run (⌘R)
- No external dependencies
- Also supports iOS 26.0+ and visionOS 26.0+ (though primarily designed for macOS)

## Architecture

### Core Components

1. **Shader System**
   - `ShaderBoilerplate.metal.txt` - Contains the Metal kernel wrapper and helper functions (rotate2D, rotate3D, hsv, noise functions, etc.)
   - User shaders only need to implement: `float4 mainImage(float2 position, float2 resolution, float2 mouse, float time, float frame, texture2d<float, access::read> backbuffer)`
   - Dynamic compilation happens in `Renderer.swift` by replacing `// USER_SHADER_CODE` placeholder

2. **Rendering Pipeline**
   - `Renderer.swift` - MTKViewDelegate that manages double buffering (textureA/textureB swap each frame)
   - `RenderShaders.metal` - Simple vertex/fragment shaders to display the computed texture
   - Note: ComputeShader.metal was removed - all shaders now use dynamic compilation

3. **UI Architecture**
   - `ContentView.swift` - Main UI with HSplitView containing MetalView and shader editor
   - `MetalView.swift` - NSViewRepresentable wrapper for MTKView
   - Examples menu loads `.metal.txt` files from the Examples directory

### Shader Examples Organization

All example shaders are in `Phosphor/Examples/` as `.metal.txt` files. The menu system strips " (Experimental)" suffixes when loading files.

### Key Implementation Details

- **Coordinate System**: `position` parameter is in pixel coordinates (0,0 is bottom-left)
- **Backbuffer Access**: Uses `texture2d.read()` with `uint2` coordinates (not `.sample()`)
- **Texture Format**: `rgba32Float` for high precision
- **Mouse Input**: Currently hardcoded to (0.5, 0.5) in Renderer

### Common Issues

1. **Raymarching shaders** - Many have coordinate system issues producing "laser show" effects
2. **Backbuffer-dependent shaders** - Water Ripples and Reaction-Diffusion marked as experimental due to texture reading complexities
3. **Helper functions** - All shaders have access to noise functions, HSV conversion, and rotation matrices from the boilerplate

## Code Quality

The project has a comprehensive SwiftLint configuration (`.swiftlint.yml`) with 200+ enabled rules. Known violations that need addressing:
- Force unwrapping (10 violations)
- Force try (2 violations)
- No magic numbers (16 violations)
- Explicit access control (31 violations)

To check linting issues, run SwiftLint from Xcode or command line (if installed).

## Shader Development

When creating new shaders:
1. Create a `.metal.txt` file in Examples directory
2. Implement only the `mainImage` function
3. Add the filename to `shaderExamples` array in ContentView.swift
4. Use available helper functions: `rotate2D()`, `rotate3D()`, `hsv()`, `fsnoise()`, `snoise2D()`, `snoise3D()`, `snoise4D()`

### Current Shader Examples

The app includes various shader examples:
- **Working**: HelloTriangle, Checkerboard, RaymarchingSphere, VoronoiCells, Plasma, Fire, Heart, IterativeTrig, FractalKaleidoscope, TerrainRiver, NoiseFlow, Cityscape
- **Experimental**: WaterRipples, ReactionDiffusion (backbuffer reading issues)
- **Broken**: FractalPlant, HSVRaymarch, BrokenShader (coordinate system/rendering issues)