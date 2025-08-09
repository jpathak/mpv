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

#import <Metal/Metal.h>
#include "common/common.h"
#include "common/msg.h"
#include "metal_shader_compiler.h"

// Use simplified logging for now
#define MP_LOG_ERR(log, fmt, ...) fprintf(stderr, fmt, __VA_ARGS__)

// Embedded shader source
static const char* metal_shader_source = 
#include "metal_shaders.metal.h"
;

struct metal_shader_compiler {
    id<MTLDevice> device;
    id<MTLLibrary> library;
    NSMutableDictionary *function_cache;
    NSMutableDictionary *pipeline_cache;
    struct mp_log *log;
};

struct metal_shader_compiler *metal_shader_compiler_create(id<MTLDevice> device, struct mp_log *log)
{
    struct metal_shader_compiler *compiler = talloc_zero(NULL, struct metal_shader_compiler);
    compiler->device = device;
    compiler->log = log;
    compiler->function_cache = [[NSMutableDictionary alloc] init];
    compiler->pipeline_cache = [[NSMutableDictionary alloc] init];
    
    // Compile default library from embedded source
    NSError *error = nil;
    NSString *source = [NSString stringWithUTF8String:metal_shader_source];
    compiler->library = [device newLibraryWithSource:source options:nil error:&error];
    
    if (error) {
        MP_LOG_ERR(log, "Failed to compile Metal shaders: %s\n", [[error description] UTF8String]);
        metal_shader_compiler_destroy(compiler);
        return NULL;
    }
    
    return compiler;
}

void metal_shader_compiler_destroy(struct metal_shader_compiler *compiler)
{
    if (!compiler)
        return;
    
    [compiler->function_cache release];
    [compiler->pipeline_cache release];
    [compiler->library release];
    
    talloc_free(compiler);
}

id<MTLFunction> metal_shader_compiler_get_function(struct metal_shader_compiler *compiler,
                                                   const char *name)
{
    if (!compiler || !name)
        return nil;
    
    NSString *key = [NSString stringWithUTF8String:name];
    id<MTLFunction> function = compiler->function_cache[key];
    
    if (!function) {
        function = [compiler->library newFunctionWithName:key];
        if (function) {
            compiler->function_cache[key] = function;
        } else {
            MP_LOG_ERR(compiler->log, "Function '%s' not found in Metal library\n", name);
        }
    }
    
    return function;
}

id<MTLRenderPipelineState> metal_shader_compiler_get_pipeline(
    struct metal_shader_compiler *compiler,
    const char *vertex_function,
    const char *fragment_function,
    MTLPixelFormat color_format,
    MTLPixelFormat depth_format)
{
    if (!compiler || !vertex_function || !fragment_function)
        return nil;
    
    // Create cache key
    NSString *key = [NSString stringWithFormat:@"%s_%s_%lu_%lu",
                     vertex_function, fragment_function,
                     (unsigned long)color_format, (unsigned long)depth_format];
    
    id<MTLRenderPipelineState> pipeline = compiler->pipeline_cache[key];
    if (pipeline)
        return pipeline;
    
    // Get functions
    id<MTLFunction> vert_func = metal_shader_compiler_get_function(compiler, vertex_function);
    id<MTLFunction> frag_func = metal_shader_compiler_get_function(compiler, fragment_function);
    
    if (!vert_func || !frag_func)
        return nil;
    
    // Create pipeline descriptor
    MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.vertexFunction = vert_func;
    desc.fragmentFunction = frag_func;
    desc.colorAttachments[0].pixelFormat = color_format;
    
    // Enable blending for overlay operations
    desc.colorAttachments[0].blendingEnabled = YES;
    desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    desc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
    desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    
    if (depth_format != MTLPixelFormatInvalid) {
        desc.depthAttachmentPixelFormat = depth_format;
    }
    
    // Create pipeline state
    NSError *error = nil;
    pipeline = [compiler->device newRenderPipelineStateWithDescriptor:desc error:&error];
    [desc release];
    
    if (error) {
        MP_LOG_ERR(compiler->log, "Failed to create pipeline: %s\n", [[error description] UTF8String]);
        return nil;
    }
    
    // Cache the pipeline
    compiler->pipeline_cache[key] = pipeline;
    
    return pipeline;
}

id<MTLComputePipelineState> metal_shader_compiler_get_compute_pipeline(
    struct metal_shader_compiler *compiler,
    const char *function_name)
{
    if (!compiler || !function_name)
        return nil;
    
    NSString *key = [NSString stringWithFormat:@"compute_%s", function_name];
    id<MTLComputePipelineState> pipeline = compiler->pipeline_cache[key];
    
    if (pipeline)
        return pipeline;
    
    id<MTLFunction> function = metal_shader_compiler_get_function(compiler, function_name);
    if (!function)
        return nil;
    
    NSError *error = nil;
    pipeline = [compiler->device newComputePipelineStateWithFunction:function error:&error];
    
    if (error) {
        MP_LOG_ERR(compiler->log, "Failed to create compute pipeline: %s\n", [[error description] UTF8String]);
        return nil;
    }
    
    compiler->pipeline_cache[key] = pipeline;
    
    return pipeline;
}

// GLSL to Metal shader translation helper (simplified)
NSString *metal_shader_translate_glsl(const char *glsl_source, 
                                      enum metal_shader_type type,
                                      struct mp_log *log)
{
    // This is a simplified translator - in production, use SPIRV-Cross or similar
    NSMutableString *metal_source = [NSMutableString string];
    
    [metal_source appendString:@"#include <metal_stdlib>\n"];
    [metal_source appendString:@"using namespace metal;\n\n"];
    
    // Parse and translate GLSL to MSL
    // This would require a proper GLSL parser in production
    NSString *glsl = [NSString stringWithUTF8String:glsl_source];
    
    // Basic replacements
    glsl = [glsl stringByReplacingOccurrencesOfString:@"vec2" withString:@"float2"];
    glsl = [glsl stringByReplacingOccurrencesOfString:@"vec3" withString:@"float3"];
    glsl = [glsl stringByReplacingOccurrencesOfString:@"vec4" withString:@"float4"];
    glsl = [glsl stringByReplacingOccurrencesOfString:@"mat4" withString:@"float4x4"];
    glsl = [glsl stringByReplacingOccurrencesOfString:@"texture2D" withString:@"texture.sample"];
    glsl = [glsl stringByReplacingOccurrencesOfString:@"gl_FragColor" withString:@"return"];
    
    if (type == METAL_SHADER_VERTEX) {
        [metal_source appendString:@"struct VertexOut {\n"];
        [metal_source appendString:@"    float4 position [[position]];\n"];
        [metal_source appendString:@"    float2 texcoord;\n"];
        [metal_source appendString:@"};\n\n"];
        [metal_source appendString:@"vertex VertexOut vertex_main(\n"];
        [metal_source appendString:@"    float2 position [[attribute(0)]],\n"];
        [metal_source appendString:@"    float2 texcoord [[attribute(1)]]\n"];
        [metal_source appendString:@") {\n"];
        [metal_source appendString:@"    VertexOut out;\n"];
        // Add translated shader body
        [metal_source appendString:glsl];
        [metal_source appendString:@"    return out;\n"];
        [metal_source appendString:@"}\n"];
    } else if (type == METAL_SHADER_FRAGMENT) {
        [metal_source appendString:@"struct VertexOut {\n"];
        [metal_source appendString:@"    float4 position [[position]];\n"];
        [metal_source appendString:@"    float2 texcoord;\n"];
        [metal_source appendString:@"};\n\n"];
        [metal_source appendString:@"fragment float4 fragment_main(\n"];
        [metal_source appendString:@"    VertexOut in [[stage_in]],\n"];
        [metal_source appendString:@"    texture2d<float> tex [[texture(0)]],\n"];
        [metal_source appendString:@"    sampler samp [[sampler(0)]]\n"];
        [metal_source appendString:@") {\n"];
        // Add translated shader body
        [metal_source appendString:glsl];
        [metal_source appendString:@"}\n"];
    }
    
    return metal_source;
}