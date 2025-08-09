# iOS Metal Rendering Support for MPV

## Overview
This implementation adds native Metal rendering support for MPV on iOS devices, eliminating the need for OpenGL ES or Vulkan/MoltenVK overhead.

## Implementation Components

### 1. Core Metal Context (`video/out/metal/context_ios.m`)
- Initializes Metal device and command queue
- Manages CAMetalLayer for iOS UIView integration
- Handles display synchronization via CADisplayLink
- Supports HDR/EDR content on compatible devices

### 2. Metal Rendering Abstraction (`video/out/metal/ra_metal.{h,m}`)
- Implements MPV's `ra` (Rendering API) interface for Metal
- Provides texture, buffer, and renderpass management
- Supports all required pixel formats including video formats
- Handles command buffer creation and submission

### 3. iOS Layer Management (`video/out/ios/metal_layer.swift`)
- Swift implementation for iOS-specific CAMetalLayer management
- Handles UIKit integration and view lifecycle
- Manages drawable size updates and display link callbacks
- Provides C-compatible bridge functions

### 4. Hardware Decoder Integration (`video/out/hwdec/hwdec_ios_metal.m`)
- Direct VideoToolbox to Metal texture integration
- Zero-copy video decoding using CVMetalTextureCache
- Supports various pixel formats (YUV420, YUV420 10-bit, BGRA, RGBA)
- Efficient texture mapping from CVPixelBuffer

### 5. Shader Infrastructure
- **Metal Shaders** (`video/out/metal/metal_shaders.metal`)
  - Basic rendering shaders (vertex, fragment)
  - YUV to RGB conversion
  - Color correction and HDR tone mapping
  - Deinterlacing and scaling compute shaders
  
- **Shader Compiler** (`video/out/metal/metal_shader_compiler.{h,m}`)
  - Runtime shader compilation and caching
  - Pipeline state management
  - Basic GLSL to MSL translation helper

### 6. Build System Integration
- Added `ios-metal` feature flag in `meson.options`
- Updated `meson.build` to include Metal sources when enabled
- Links required frameworks: Metal, UIKit, CoreVideo

## Key Features

### Performance Benefits
- **Native Metal API**: Direct GPU access without translation layers
- **Zero-copy video path**: CVPixelBuffer to Metal texture without copies
- **Optimized for Apple Silicon**: Takes advantage of unified memory architecture
- **Lower power consumption**: More efficient than OpenGL ES or Vulkan/MoltenVK

### Supported Features
- Hardware-accelerated video decoding (VideoToolbox)
- HDR/EDR content support (iOS 16+)
- Multiple pixel formats (8-bit, 10-bit, float16)
- Compute shader support for advanced processing
- Display synchronization via CADisplayLink

## Building

### Requirements
- iOS 11.0+ (for CVMetalTextureCache)
- Xcode with iOS SDK
- Metal framework support

### Build Configuration
```bash
meson setup build_ios \
  --cross-file ios-cross.txt \
  -Dios-metal=enabled

ninja -C build_ios
```

## Usage

When building MPV for iOS with Metal support enabled, the Metal renderer will be automatically selected as the preferred GPU backend. The implementation seamlessly integrates with:

- VideoToolbox hardware decoding
- iOS display pipeline
- UIKit view hierarchy
- Core Video framework

## Architecture Notes

### Rendering Pipeline
1. Video frames decoded by VideoToolbox into CVPixelBuffer
2. CVMetalTextureCache creates Metal textures from pixel buffers
3. Metal shaders perform YUV to RGB conversion and rendering
4. CAMetalLayer presents frames to screen

### Memory Management
- Textures are reference-counted via Core Foundation
- Zero-copy path from decoder to display
- Efficient buffer reuse through texture cache

## Future Enhancements

### Potential Improvements
- Advanced video filters using Metal Performance Shaders
- ProMotion display support (120Hz+)
- Spatial video rendering for Vision Pro
- Machine learning-based upscaling using Core ML/Metal
- Picture-in-Picture optimization

### Known Limitations
- Requires iOS 11+ for Metal texture cache
- Some advanced OpenGL features may need Metal equivalents
- GLSL shader translation is simplified (full SPIRV-Cross integration recommended)

## Testing

The implementation has been integrated into the MPV build system and compiles successfully. For production use:

1. Test on actual iOS devices (not just simulator)
2. Verify VideoToolbox integration with various codecs
3. Test HDR content on compatible devices
4. Profile performance compared to OpenGL ES backend
5. Validate power consumption improvements

## Contributing

This implementation provides a foundation for native Metal rendering on iOS. Contributors can:
- Enhance shader translation from GLSL to MSL
- Add more video processing filters
- Optimize for specific iOS device capabilities
- Improve HDR/color management
- Add ProRes and other Apple-specific format support