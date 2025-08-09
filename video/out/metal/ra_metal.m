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
#import <simd/simd.h>

#include "ra_metal.h"
#include "common/common.h"
#include "common/msg.h"
#include "video/out/gpu/utils.h"

struct priv {
    id<MTLDevice> device;
    id<MTLCommandQueue> command_queue;
    id<MTLCommandBuffer> current_command_buffer;
    id<MTLRenderCommandEncoder> current_render_encoder;
    id<MTLLibrary> library;
    id<MTLRenderPipelineState> current_pipeline;
    NSMutableDictionary *pipeline_cache;
    NSMutableDictionary *shader_cache;
    struct mp_log *log;
};

struct ra_tex_metal {
    id<MTLTexture> texture;
    id<MTLSamplerState> sampler;
    bool owned;
};

struct ra_buf_metal {
    id<MTLBuffer> buffer;
    size_t size;
    void *data;
    bool coherent;
};

struct ra_renderpass_metal {
    id<MTLRenderPipelineState> pipeline;
    id<MTLDepthStencilState> depth_stencil;
    MTLPixelFormat color_format;
    MTLPixelFormat depth_format;
};

// Forward declarations
static void metal_destroy(struct ra *ra);
static void metal_tex_destroy(struct ra *ra, struct ra_tex *tex);
static struct ra_tex *metal_tex_create(struct ra *ra, const struct ra_tex_params *params);
static bool metal_tex_upload(struct ra *ra, const struct ra_tex_upload_params *params);
static bool metal_tex_download(struct ra *ra, struct ra_tex_download_params *params);
static void metal_buf_destroy(struct ra *ra, struct ra_buf *buf);
static struct ra_buf *metal_buf_create(struct ra *ra, const struct ra_buf_params *params);
static void metal_buf_update(struct ra *ra, struct ra_buf *buf, ptrdiff_t offset, const void *data, size_t size);
static bool metal_buf_poll(struct ra *ra, struct ra_buf *buf);
static void metal_clear(struct ra *ra, struct ra_tex *dst, float color[4], struct mp_rect *scissor);
static void metal_blit(struct ra *ra, struct ra_tex *dst, struct ra_tex *src, struct mp_rect *dst_rc, struct mp_rect *src_rc);
static int metal_desc_namespace(struct ra *ra, enum ra_vartype type);
static struct ra_renderpass *metal_renderpass_create(struct ra *ra, const struct ra_renderpass_params *params);
static void metal_renderpass_destroy(struct ra *ra, struct ra_renderpass *pass);
static void metal_renderpass_run(struct ra *ra, const struct ra_renderpass_run_params *params);

static const struct ra_fns ra_fns_metal = {
    .destroy = metal_destroy,
    .tex_create = metal_tex_create,
    .tex_destroy = metal_tex_destroy,
    .tex_upload = metal_tex_upload,
    .tex_download = metal_tex_download,
    .buf_create = metal_buf_create,
    .buf_destroy = metal_buf_destroy,
    .buf_update = metal_buf_update,
    .buf_poll = metal_buf_poll,
    .clear = metal_clear,
    .blit = metal_blit,
    .desc_namespace = metal_desc_namespace,
    .renderpass_create = metal_renderpass_create,
    .renderpass_destroy = metal_renderpass_destroy,
    .renderpass_run = metal_renderpass_run,
};

static MTLPixelFormat ra_fmt_to_metal(const struct ra_format *fmt)
{
    // Map common formats
    if (fmt->ctype == RA_CTYPE_UNORM) {
        if (fmt->num_components == 1 && fmt->component_size[0] == 8)
            return MTLPixelFormatR8Unorm;
        if (fmt->num_components == 2 && fmt->component_size[0] == 8)
            return MTLPixelFormatRG8Unorm;
        if (fmt->num_components == 4 && fmt->component_size[0] == 8)
            return MTLPixelFormatRGBA8Unorm;
    } else if (fmt->ctype == RA_CTYPE_FLOAT) {
        if (fmt->num_components == 1 && fmt->component_size[0] == 16)
            return MTLPixelFormatR16Float;
        if (fmt->num_components == 2 && fmt->component_size[0] == 16)
            return MTLPixelFormatRG16Float;
        if (fmt->num_components == 4 && fmt->component_size[0] == 16)
            return MTLPixelFormatRGBA16Float;
        if (fmt->num_components == 1 && fmt->component_size[0] == 32)
            return MTLPixelFormatR32Float;
        if (fmt->num_components == 2 && fmt->component_size[0] == 32)
            return MTLPixelFormatRG32Float;
        if (fmt->num_components == 4 && fmt->component_size[0] == 32)
            return MTLPixelFormatRGBA32Float;
    }
    
    return MTLPixelFormatInvalid;
}

static void add_format(struct ra *ra, MTLPixelFormat metal_fmt, const char *name,
                      enum ra_ctype ctype, int num_components, int component_size,
                      bool renderable, bool linear_filter)
{
    struct ra_format *fmt = talloc_zero(ra, struct ra_format);
    fmt->name = name;
    fmt->priv = (void *)(uintptr_t)metal_fmt;
    fmt->ctype = ctype;
    fmt->num_components = num_components;
    fmt->ordered = true;
    fmt->pixel_size = (num_components * component_size) / 8;
    fmt->linear_filter = linear_filter;
    fmt->renderable = renderable;
    
    for (int i = 0; i < num_components; i++) {
        fmt->component_size[i] = component_size;
        fmt->component_depth[i] = component_size;
    }
    
    MP_TARRAY_APPEND(ra, ra->formats, ra->num_formats, fmt);
}

struct ra *ra_metal_create(id<MTLDevice> device, id<MTLCommandQueue> queue, struct mp_log *log)
{
    struct ra *ra = talloc_zero(NULL, struct ra);
    ra->log = log;
    ra->fns = &ra_fns_metal;
    
    struct priv *p = ra->priv = talloc_zero(ra, struct priv);
    p->device = device;
    p->command_queue = queue;
    p->log = log;
    p->pipeline_cache = [[NSMutableDictionary alloc] init];
    p->shader_cache = [[NSMutableDictionary alloc] init];
    
    // Set capabilities
    ra->caps = RA_CAP_TEX_1D | RA_CAP_TEX_3D | RA_CAP_BLIT | RA_CAP_COMPUTE |
               RA_CAP_DIRECT_UPLOAD | RA_CAP_BUF_RO | RA_CAP_BUF_RW |
               RA_CAP_NESTED_ARRAY | RA_CAP_PARALLEL_COMPUTE;
    
    ra->glsl_version = 450; // Metal Shading Language is similar to GLSL 4.5
    ra->glsl_vulkan = true;  // MSL is closer to Vulkan GLSL
    
    // Set limits
    ra->max_texture_wh = 16384; // iOS typically supports at least 16k textures
    if (@available(iOS 13.0, *)) {
        ra->max_texture_wh = [device supportsFamily:MTLGPUFamilyApple4] ? 16384 : 8192;
    }
    
    ra->max_shmem = 32 * 1024; // 32KB threadgroup memory
    ra->max_compute_group_threads = 1024;
    ra->max_pushc_size = 4096; // 4KB for inline constants
    
    // Add texture formats
    add_format(ra, MTLPixelFormatR8Unorm, "r8", RA_CTYPE_UNORM, 1, 8, true, true);
    add_format(ra, MTLPixelFormatRG8Unorm, "rg8", RA_CTYPE_UNORM, 2, 8, true, true);
    add_format(ra, MTLPixelFormatRGBA8Unorm, "rgba8", RA_CTYPE_UNORM, 4, 8, true, true);
    add_format(ra, MTLPixelFormatR16Float, "r16f", RA_CTYPE_FLOAT, 1, 16, true, true);
    add_format(ra, MTLPixelFormatRG16Float, "rg16f", RA_CTYPE_FLOAT, 2, 16, true, true);
    add_format(ra, MTLPixelFormatRGBA16Float, "rgba16f", RA_CTYPE_FLOAT, 4, 16, true, true);
    add_format(ra, MTLPixelFormatR32Float, "r32f", RA_CTYPE_FLOAT, 1, 32, true, true);
    add_format(ra, MTLPixelFormatRG32Float, "rg32f", RA_CTYPE_FLOAT, 2, 32, true, true);
    add_format(ra, MTLPixelFormatRGBA32Float, "rgba32f", RA_CTYPE_FLOAT, 4, 32, false, true);
    
    // Add special formats for video
    add_format(ra, MTLPixelFormatBGRA8Unorm, "bgra8", RA_CTYPE_UNORM, 4, 8, true, true);
    
    // Create default library
    NSError *error = nil;
    p->library = [device newDefaultLibrary];
    if (!p->library) {
        fprintf(stderr, "Failed to create default Metal library\n");
        metal_destroy(ra);
        return NULL;
    }
    
    return ra;
}

void ra_metal_destroy(struct ra *ra)
{
    if (!ra)
        return;
    metal_destroy(ra);
}

static void metal_destroy(struct ra *ra)
{
    struct priv *p = ra->priv;
    
    if (p->current_render_encoder) {
        [p->current_render_encoder endEncoding];
        p->current_render_encoder = nil;
    }
    
    if (p->current_command_buffer) {
        [p->current_command_buffer commit];
        p->current_command_buffer = nil;
    }
    
    [p->pipeline_cache release];
    [p->shader_cache release];
    
    talloc_free(ra);
}

static void metal_tex_destroy(struct ra *ra, struct ra_tex *tex)
{
    if (!tex)
        return;
    
    struct ra_tex_metal *tex_p = tex->priv;
    if (tex_p->owned && tex_p->texture) {
        [tex_p->texture release];
    }
    if (tex_p->sampler) {
        [tex_p->sampler release];
    }
    
    talloc_free(tex);
}

static struct ra_tex *metal_tex_create(struct ra *ra, const struct ra_tex_params *params)
{
    struct priv *p = ra->priv;
    
    struct ra_tex *tex = talloc_zero(NULL, struct ra_tex);
    tex->params = *params;
    tex->params.initial_data = NULL;
    
    struct ra_tex_metal *tex_p = tex->priv = talloc_zero(tex, struct ra_tex_metal);
    tex_p->owned = true;
    
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:ra_fmt_to_metal(params->format)
                                                                                     width:params->w
                                                                                    height:params->h
                                                                                 mipmapped:NO];
    
    if (params->dimensions == 1) {
        desc.textureType = MTLTextureType1D;
        desc.height = 1;
        desc.depth = 1;
    } else if (params->dimensions == 3) {
        desc.textureType = MTLTextureType3D;
        desc.depth = params->d;
    }
    
    desc.usage = MTLTextureUsageShaderRead;
    if (params->render_dst)
        desc.usage |= MTLTextureUsageRenderTarget;
    if (params->storage_dst)
        desc.usage |= MTLTextureUsageShaderWrite;
    
    desc.storageMode = MTLStorageModePrivate;
    if (params->host_mutable || params->initial_data) {
        desc.storageMode = MTLStorageModeShared;
    }
    
    tex_p->texture = [p->device newTextureWithDescriptor:desc];
    if (!tex_p->texture) {
        MP_ERR(ra, "Failed to create Metal texture\n");
        talloc_free(tex);
        return NULL;
    }
    
    // Upload initial data if provided
    if (params->initial_data) {
        [tex_p->texture replaceRegion:MTLRegionMake2D(0, 0, params->w, params->h)
                           mipmapLevel:0
                                 slice:0
                           withBytes:params->initial_data
                         bytesPerRow:params->w * params->format->pixel_size
                       bytesPerImage:0];
    }
    
    // Create sampler if needed
    if (params->render_src) {
        MTLSamplerDescriptor *sampler_desc = [[MTLSamplerDescriptor new] autorelease];
        sampler_desc.minFilter = params->src_linear ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
        sampler_desc.magFilter = params->src_linear ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
        sampler_desc.sAddressMode = params->src_repeat ? MTLSamplerAddressModeRepeat : MTLSamplerAddressModeClampToEdge;
        sampler_desc.tAddressMode = params->src_repeat ? MTLSamplerAddressModeRepeat : MTLSamplerAddressModeClampToEdge;
        sampler_desc.rAddressMode = params->src_repeat ? MTLSamplerAddressModeRepeat : MTLSamplerAddressModeClampToEdge;
        
        tex_p->sampler = [p->device newSamplerStateWithDescriptor:sampler_desc];
    }
    
    return tex;
}

static bool metal_tex_upload(struct ra *ra, const struct ra_tex_upload_params *params)
{
    struct ra_tex_metal *tex_p = params->tex->priv;
    
    if (!params->src || !tex_p->texture)
        return false;
    
    const struct ra_tex_params *tex_params = &params->tex->params;
    size_t bytes_per_row = tex_params->w * tex_params->format->pixel_size;
    
    if (params->buf) {
        // Upload from buffer
        struct ra_buf_metal *buf_p = params->buf->priv;
        
        struct priv *p = ra->priv;
        id<MTLBlitCommandEncoder> blit = [[p->command_queue commandBuffer] blitCommandEncoder];
        
        [blit copyFromBuffer:buf_p->buffer
                sourceOffset:params->buf_offset
           sourceBytesPerRow:bytes_per_row
         sourceBytesPerImage:bytes_per_row * tex_params->h
                  sourceSize:MTLSizeMake(tex_params->w, tex_params->h, 1)
                   toTexture:tex_p->texture
            destinationSlice:0
            destinationLevel:0
           destinationOrigin:MTLOriginMake(0, 0, 0)];
        
        [blit endEncoding];
        [[p->command_queue commandBuffer] commit];
    } else {
        // Direct upload
        [tex_p->texture replaceRegion:MTLRegionMake2D(0, 0, tex_params->w, tex_params->h)
                           mipmapLevel:0
                                 slice:0
                           withBytes:params->src
                         bytesPerRow:bytes_per_row
                       bytesPerImage:0];
    }
    
    return true;
}

static bool metal_tex_download(struct ra *ra, struct ra_tex_download_params *params)
{
    struct ra_tex_metal *tex_p = params->tex->priv;
    
    if (!params->dst || !tex_p->texture)
        return false;
    
    const struct ra_tex_params *tex_params = &params->tex->params;
    size_t bytes_per_row = tex_params->w * tex_params->format->pixel_size;
    
    [tex_p->texture getBytes:params->dst
                 bytesPerRow:bytes_per_row
                      region:MTLRegionMake2D(0, 0, tex_params->w, tex_params->h)
                 mipmapLevel:0];
    
    return true;
}

static void metal_buf_destroy(struct ra *ra, struct ra_buf *buf)
{
    if (!buf)
        return;
    
    struct ra_buf_metal *buf_p = buf->priv;
    if (buf_p->buffer) {
        [buf_p->buffer release];
    }
    
    talloc_free(buf);
}

static struct ra_buf *metal_buf_create(struct ra *ra, const struct ra_buf_params *params)
{
    struct priv *p = ra->priv;
    
    struct ra_buf *buf = talloc_zero(NULL, struct ra_buf);
    buf->params = *params;
    buf->params.initial_data = NULL;
    
    struct ra_buf_metal *buf_p = buf->priv = talloc_zero(buf, struct ra_buf_metal);
    buf_p->size = params->size;
    
    MTLResourceOptions options = MTLResourceStorageModeShared;
    if (!params->host_mutable) {
        options = MTLResourceStorageModePrivate;
    }
    
    if (params->initial_data) {
        buf_p->buffer = [p->device newBufferWithBytes:params->initial_data
                                                length:params->size
                                               options:options];
    } else {
        buf_p->buffer = [p->device newBufferWithLength:params->size
                                                options:options];
    }
    
    if (!buf_p->buffer) {
        MP_ERR(ra, "Failed to create Metal buffer\n");
        talloc_free(buf);
        return NULL;
    }
    
    if (params->host_mapped) {
        buf_p->data = [buf_p->buffer contents];
        buf->data = buf_p->data;
    }
    
    return buf;
}

static void metal_buf_update(struct ra *ra, struct ra_buf *buf, ptrdiff_t offset,
                             const void *data, size_t size)
{
    struct ra_buf_metal *buf_p = buf->priv;
    
    if (!buf_p->buffer || !data)
        return;
    
    if (buf_p->data) {
        // Directly update mapped buffer
        memcpy((uint8_t *)buf_p->data + offset, data, size);
    } else {
        // Use blit encoder for private buffers
        struct priv *p = ra->priv;
        id<MTLBuffer> staging = [p->device newBufferWithBytes:data
                                                        length:size
                                                       options:MTLResourceStorageModeShared];
        
        id<MTLBlitCommandEncoder> blit = [[p->command_queue commandBuffer] blitCommandEncoder];
        [blit copyFromBuffer:staging
                sourceOffset:0
                    toBuffer:buf_p->buffer
           destinationOffset:offset
                        size:size];
        [blit endEncoding];
        [[p->command_queue commandBuffer] commit];
        
        [staging release];
    }
}

static bool metal_buf_poll(struct ra *ra, struct ra_buf *buf)
{
    // Metal buffers are always ready
    return true;
}

static void metal_clear(struct ra *ra, struct ra_tex *dst, float color[4],
                        struct mp_rect *scissor)
{
    struct priv *p = ra->priv;
    struct ra_tex_metal *dst_p = dst->priv;
    
    if (!dst_p->texture)
        return;
    
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = dst_p->texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(color[0], color[1], color[2], color[3]);
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    
    id<MTLCommandBuffer> cmd = [p->command_queue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [cmd renderCommandEncoderWithDescriptor:pass];
    
    if (scissor) {
        MTLScissorRect rect = {
            .x = scissor->x0,
            .y = scissor->y0,
            .width = scissor->x1 - scissor->x0,
            .height = scissor->y1 - scissor->y0
        };
        [encoder setScissorRect:rect];
    }
    
    [encoder endEncoding];
    [cmd commit];
}

static void metal_blit(struct ra *ra, struct ra_tex *dst, struct ra_tex *src,
                      struct mp_rect *dst_rc, struct mp_rect *src_rc)
{
    struct priv *p = ra->priv;
    struct ra_tex_metal *dst_p = dst->priv;
    struct ra_tex_metal *src_p = src->priv;
    
    if (!dst_p->texture || !src_p->texture)
        return;
    
    id<MTLCommandBuffer> cmd = [p->command_queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [cmd blitCommandEncoder];
    
    MTLOrigin src_origin = MTLOriginMake(src_rc->x0, src_rc->y0, 0);
    MTLSize src_size = MTLSizeMake(src_rc->x1 - src_rc->x0,
                                    src_rc->y1 - src_rc->y0, 1);
    MTLOrigin dst_origin = MTLOriginMake(dst_rc->x0, dst_rc->y0, 0);
    
    [blit copyFromTexture:src_p->texture
              sourceSlice:0
              sourceLevel:0
             sourceOrigin:src_origin
               sourceSize:src_size
                toTexture:dst_p->texture
         destinationSlice:0
         destinationLevel:0
        destinationOrigin:dst_origin];
    
    [blit endEncoding];
    [cmd commit];
}

static int metal_desc_namespace(struct ra *ra, enum ra_vartype type)
{
    // Metal uses different binding points for different resource types
    switch (type) {
        case RA_VARTYPE_TEX:
        case RA_VARTYPE_IMG_W:
            return 0; // Texture binding space
        case RA_VARTYPE_BUF_RO:
        case RA_VARTYPE_BUF_RW:
            return 1; // Buffer binding space
        default:
            return 0;
    }
}

static struct ra_renderpass *metal_renderpass_create(struct ra *ra,
                                                     const struct ra_renderpass_params *params)
{
    struct priv *p = ra->priv;
    
    struct ra_renderpass *pass = talloc_zero(NULL, struct ra_renderpass);
    pass->params = *ra_renderpass_params_copy(pass, params);
    
    struct ra_renderpass_metal *pass_p = pass->priv = talloc_zero(pass, struct ra_renderpass_metal);
    
    // For now, create a simple pipeline
    // In a full implementation, this would compile shaders and create proper pipeline state
    MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
    
    if (params->target_format) {
        pass_p->color_format = ra_fmt_to_metal(params->target_format);
        desc.colorAttachments[0].pixelFormat = pass_p->color_format;
    }
    
    // Create vertex and fragment functions from shader source
    // This is simplified - real implementation would parse and compile GLSL to MSL
    NSError *error = nil;
    NSString *shader_src = @"#include <metal_stdlib>\n"
                          @"using namespace metal;\n"
                          @"vertex float4 vertex_main(uint vid [[vertex_id]]) {\n"
                          @"    float2 pos[] = {float2(-1,-1), float2(3,-1), float2(-1,3)};\n"
                          @"    return float4(pos[vid], 0, 1);\n"
                          @"}\n"
                          @"fragment float4 fragment_main() {\n"
                          @"    return float4(1, 0, 0, 1);\n"
                          @"}";
    
    id<MTLLibrary> library = [p->device newLibraryWithSource:shader_src options:nil error:&error];
    if (error) {
        MP_ERR(ra, "Failed to compile shader: %s\n", [[error description] UTF8String]);
        talloc_free(pass);
        return NULL;
    }
    
    desc.vertexFunction = [library newFunctionWithName:@"vertex_main"];
    desc.fragmentFunction = [library newFunctionWithName:@"fragment_main"];
    
    error = nil;
    pass_p->pipeline = [p->device newRenderPipelineStateWithDescriptor:desc error:&error];
    [desc release];
    
    if (error) {
        MP_ERR(ra, "Failed to create pipeline: %s\n", [[error description] UTF8String]);
        talloc_free(pass);
        return NULL;
    }
    
    return pass;
}

static void metal_renderpass_destroy(struct ra *ra, struct ra_renderpass *pass)
{
    if (!pass)
        return;
    
    struct ra_renderpass_metal *pass_p = pass->priv;
    if (pass_p->pipeline) {
        [pass_p->pipeline release];
    }
    if (pass_p->depth_stencil) {
        [pass_p->depth_stencil release];
    }
    
    talloc_free(pass);
}

static void metal_renderpass_run(struct ra *ra, const struct ra_renderpass_run_params *params)
{
    struct priv *p = ra->priv;
    struct ra_renderpass *pass = params->pass;
    struct ra_renderpass_metal *pass_p = pass->priv;
    
    if (!pass_p->pipeline)
        return;
    
    MTLRenderPassDescriptor *render_pass = [MTLRenderPassDescriptor renderPassDescriptor];
    
    if (params->target) {
        struct ra_tex_metal *target_p = params->target->priv;
        render_pass.colorAttachments[0].texture = target_p->texture;
        render_pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
        render_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    }
    
    id<MTLCommandBuffer> cmd = [p->command_queue commandBuffer];
    id<MTLRenderCommandEncoder> encoder = [cmd renderCommandEncoderWithDescriptor:render_pass];
    
    [encoder setRenderPipelineState:pass_p->pipeline];
    
    if (params->scissors.x0 > 0 || params->scissors.y0 > 0) {
        MTLScissorRect rect = {
            .x = params->scissors.x0,
            .y = params->scissors.y0,
            .width = params->scissors.x1 - params->scissors.x0,
            .height = params->scissors.y1 - params->scissors.y0
        };
        [encoder setScissorRect:rect];
    }
    
    // Bind vertex data if provided
    if (params->vertex_data) {
        [encoder setVertexBytes:params->vertex_data
                         length:params->vertex_count * pass->params.vertex_stride
                        atIndex:0];
    }
    
    // Bind textures and buffers
    for (int i = 0; i < params->num_values; i++) {
        const struct ra_renderpass_input_val *val = &params->values[i];
        const struct ra_renderpass_input *inp = &pass->params.inputs[val->index];
        
        switch (inp->type) {
            case RA_VARTYPE_TEX: {
                struct ra_tex *tex = *(struct ra_tex **)val->data;
                struct ra_tex_metal *tex_p = tex->priv;
                [encoder setFragmentTexture:tex_p->texture atIndex:inp->binding];
                if (tex_p->sampler) {
                    [encoder setFragmentSamplerState:tex_p->sampler atIndex:inp->binding];
                }
                break;
            }
            case RA_VARTYPE_BUF_RO: {
                struct ra_buf *buf = *(struct ra_buf **)val->data;
                struct ra_buf_metal *buf_p = buf->priv;
                [encoder setFragmentBuffer:buf_p->buffer offset:0 atIndex:inp->binding];
                break;
            }
            default:
                break;
        }
    }
    
    // Draw
    if (params->vertex_data) {
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                    vertexStart:0
                    vertexCount:params->vertex_count];
    } else {
        // Full screen quad
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle
                    vertexStart:0
                    vertexCount:3];
    }
    
    [encoder endEncoding];
    [cmd commit];
}

id<MTLDevice> ra_metal_get_device(const struct ra *ra)
{
    struct priv *p = ra->priv;
    return p->device;
}

id<MTLCommandBuffer> ra_metal_get_command_buffer(const struct ra *ra)
{
    struct priv *p = ra->priv;
    if (!p->current_command_buffer) {
        p->current_command_buffer = [p->command_queue commandBuffer];
    }
    return p->current_command_buffer;
}

void ra_metal_submit(const struct ra *ra)
{
    struct priv *p = ra->priv;
    if (p->current_render_encoder) {
        [p->current_render_encoder endEncoding];
        p->current_render_encoder = nil;
    }
    if (p->current_command_buffer) {
        [p->current_command_buffer commit];
        p->current_command_buffer = nil;
    }
}

bool ra_is_metal(const struct ra *ra)
{
    return ra && ra->fns == &ra_fns_metal;
}

struct ra_tex *ra_metal_wrap_texture(struct ra *ra, id<MTLTexture> texture,
                                     const struct ra_tex_params *params)
{
    if (!ra_is_metal(ra))
        return NULL;
    
    struct ra_tex *tex = talloc_zero(NULL, struct ra_tex);
    tex->params = *params;
    
    struct ra_tex_metal *tex_p = tex->priv = talloc_zero(tex, struct ra_tex_metal);
    tex_p->texture = texture;
    tex_p->owned = false;  // We don't own wrapped textures
    
    // Create sampler if needed
    if (params->render_src) {
        struct priv *p = ra->priv;
        MTLSamplerDescriptor *sampler_desc = [[MTLSamplerDescriptor new] autorelease];
        sampler_desc.minFilter = params->src_linear ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
        sampler_desc.magFilter = params->src_linear ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
        sampler_desc.sAddressMode = params->src_repeat ? MTLSamplerAddressModeRepeat : MTLSamplerAddressModeClampToEdge;
        sampler_desc.tAddressMode = params->src_repeat ? MTLSamplerAddressModeRepeat : MTLSamplerAddressModeClampToEdge;
        
        tex_p->sampler = [p->device newSamplerStateWithDescriptor:sampler_desc];
    }
    
    return tex;
}