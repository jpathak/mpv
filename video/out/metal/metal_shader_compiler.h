/*
 * This file is part of mpv.
 *
 * mpv is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * mpv is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with mpv.  If not, see <http://www.gnu.org/licenses/>.
 */

#pragma once

#include <Metal/Metal.h>

struct mp_log;
struct metal_shader_compiler;

enum metal_shader_type {
    METAL_SHADER_VERTEX,
    METAL_SHADER_FRAGMENT,
    METAL_SHADER_COMPUTE
};

// Create and destroy shader compiler
struct metal_shader_compiler *metal_shader_compiler_create(id<MTLDevice> device, struct mp_log *log);
void metal_shader_compiler_destroy(struct metal_shader_compiler *compiler);

// Get compiled shader functions
id<MTLFunction> metal_shader_compiler_get_function(struct metal_shader_compiler *compiler,
                                                   const char *name);

// Get render pipeline state
id<MTLRenderPipelineState> metal_shader_compiler_get_pipeline(
    struct metal_shader_compiler *compiler,
    const char *vertex_function,
    const char *fragment_function,
    MTLPixelFormat color_format,
    MTLPixelFormat depth_format);

// Get compute pipeline state
id<MTLComputePipelineState> metal_shader_compiler_get_compute_pipeline(
    struct metal_shader_compiler *compiler,
    const char *function_name);

// Translate GLSL to Metal Shading Language (simplified)
NSString *metal_shader_translate_glsl(const char *glsl_source, 
                                      enum metal_shader_type type,
                                      struct mp_log *log);