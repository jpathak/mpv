/*
 * Copyright (c) 2024 mpv developers
 *
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

#include <assert.h>

#include <CoreVideo/CoreVideo.h>
#include <Metal/Metal.h>

#include <libavutil/hwcontext.h>

#include "video/out/gpu/hwdec.h"
#include "video/mp_image_pool.h"
#include "video/out/metal/ra_metal.h"
#include "hwdec_vt.h"

static bool check_hwdec(const struct ra_hwdec *hw)
{
    if (!ra_is_metal(hw->ra_ctx->ra))
        return false;
    
    id<MTLDevice> device = ra_metal_get_device(hw->ra_ctx->ra);
    if (!device) {
        MP_ERR(hw, "Failed to get Metal device\n");
        return false;
    }
    
    // Check for iOS 11+ which supports Metal texture cache
    if (@available(iOS 11.0, *)) {
        return true;
    } else {
        MP_ERR(hw, "iOS 11.0 or later required for Metal texture cache\n");
        return false;
    }
}

static int mapper_init(struct ra_hwdec_mapper *mapper)
{
    struct priv *p = mapper->priv;
    
    mapper->dst_params = mapper->src_params;
    mapper->dst_params.imgfmt = mapper->src_params.hw_subfmt;
    mapper->dst_params.hw_subfmt = 0;
    
    if (!mapper->dst_params.imgfmt) {
        MP_ERR(mapper, "Unsupported CVPixelBuffer format.\n");
        return -1;
    }
    
    if (!ra_get_imgfmt_desc(mapper->ra, mapper->dst_params.imgfmt, &p->desc)) {
        MP_ERR(mapper, "Unsupported texture format.\n");
        return -1;
    }
    
    for (int n = 0; n < p->desc.num_planes; n++) {
        if (!p->desc.planes[n] || p->desc.planes[n]->ctype != RA_CTYPE_UNORM) {
            MP_ERR(mapper, "Format unsupported.\n");
            return -1;
        }
    }
    
    // Get Metal device
    id<MTLDevice> device = ra_metal_get_device(mapper->ra);
    if (!device) {
        MP_ERR(mapper, "Failed to get Metal device\n");
        return -1;
    }
    
    // Create Metal texture cache
    CVReturn err = CVMetalTextureCacheCreate(
        kCFAllocatorDefault,
        NULL,
        device,
        NULL,
        &p->mtl_texture_cache);
    
    if (err != noErr) {
        MP_ERR(mapper, "Failed to create CVMetalTextureCache: %d\n", err);
        return -1;
    }
    
    return 0;
}

static void mapper_unmap(struct ra_hwdec_mapper *mapper)
{
    struct priv *p = mapper->priv;
    
    for (int i = 0; i < p->desc.num_planes; i++) {
        ra_tex_free(mapper->ra, &mapper->tex[i]);
        if (p->mtl_planes[i]) {
            CFRelease(p->mtl_planes[i]);
            p->mtl_planes[i] = NULL;
        }
    }
    
    CVMetalTextureCacheFlush(p->mtl_texture_cache, 0);
}

static MTLPixelFormat get_metal_format(uint32_t cv_pixel_format, int plane)
{
    switch (cv_pixel_format) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            return plane == 0 ? MTLPixelFormatR8Unorm : MTLPixelFormatRG8Unorm;
            
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange:
        case kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            return plane == 0 ? MTLPixelFormatR16Unorm : MTLPixelFormatRG16Unorm;
            
        case kCVPixelFormatType_32BGRA:
            return MTLPixelFormatBGRA8Unorm;
            
        case kCVPixelFormatType_32RGBA:
            return MTLPixelFormatRGBA8Unorm;
            
        default:
            return MTLPixelFormatInvalid;
    }
}

static int mapper_map(struct ra_hwdec_mapper *mapper)
{
    struct priv *p = mapper->priv;
    
    CVPixelBufferRelease(p->pbuf);
    p->pbuf = (CVPixelBufferRef)mapper->src->planes[3];
    CVPixelBufferRetain(p->pbuf);
    
    const bool planar = CVPixelBufferIsPlanar(p->pbuf);
    const int planes = planar ? CVPixelBufferGetPlaneCount(p->pbuf) : 1;
    
    assert(planes == p->desc.num_planes);
    
    OSType cv_pixel_format = CVPixelBufferGetPixelFormatType(p->pbuf);
    
    for (int i = 0; i < p->desc.num_planes; i++) {
        size_t width = planar ? 
            CVPixelBufferGetWidthOfPlane(p->pbuf, i) : 
            CVPixelBufferGetWidth(p->pbuf);
        size_t height = planar ? 
            CVPixelBufferGetHeightOfPlane(p->pbuf, i) : 
            CVPixelBufferGetHeight(p->pbuf);
        
        MTLPixelFormat format = get_metal_format(cv_pixel_format, i);
        if (format == MTLPixelFormatInvalid) {
            MP_ERR(mapper, "Unsupported Metal pixel format for plane %d\n", i);
            return -1;
        }
        
        CVReturn err = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            p->mtl_texture_cache,
            p->pbuf,
            NULL,
            format,
            width,
            height,
            i,
            &p->mtl_planes[i]);
        
        if (err != noErr) {
            MP_ERR(mapper, "Failed to create Metal texture for plane %d: %d\n", i, err);
            return -1;
        }
        
        id<MTLTexture> mtl_texture = CVMetalTextureGetTexture(p->mtl_planes[i]);
        if (!mtl_texture) {
            MP_ERR(mapper, "Failed to get Metal texture for plane %d\n", i);
            return -1;
        }
        
        // Create ra_tex wrapper for the Metal texture
        struct ra_tex_params params = {
            .dimensions = 2,
            .w = (int)width,
            .h = (int)height,
            .d = 1,
            .format = p->desc.planes[i],
            .render_src = true,
            .src_linear = true,
        };
        
        // Create wrapped texture
        mapper->tex[i] = ra_metal_wrap_texture(mapper->ra, mtl_texture, &params);
        if (!mapper->tex[i]) {
            MP_ERR(mapper, "Failed to wrap Metal texture for plane %d\n", i);
            return -1;
        }
    }
    
    return 0;
}

static void mapper_uninit(struct ra_hwdec_mapper *mapper)
{
    struct priv *p = mapper->priv;
    
    CVPixelBufferRelease(p->pbuf);
    p->pbuf = NULL;
    
    if (p->mtl_texture_cache) {
        CFRelease(p->mtl_texture_cache);
        p->mtl_texture_cache = NULL;
    }
}

bool vt_metal_init(const struct ra_hwdec *hw)
{
    struct priv_owner *p = hw->priv;
    
    if (!check_hwdec(hw))
        return false;
    
    p->interop_init   = mapper_init;
    p->interop_uninit = mapper_uninit;
    p->interop_map    = mapper_map;
    p->interop_unmap  = mapper_unmap;
    
    return true;
}