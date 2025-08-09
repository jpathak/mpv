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

#import <Cocoa/Cocoa.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include "video/out/gpu/context.h"
#include "video/out/gpu/hwdec.h"
#include "osdep/mac/swift.h"
#include "ra_metal.h"

struct priv {
    struct ra_metal *ra_metal;
    MacCommon *vo_mac;
    CAMetalLayer *layer;
    id<MTLDevice> device;
    id<MTLCommandQueue> command_queue;
    id<CAMetalDrawable> current_drawable;
    CVDisplayLinkRef display_link;
    struct vo_vsync_info vsync_info;
};

static void mac_metal_uninit(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;
    
    if (p->display_link) {
        CVDisplayLinkStop(p->display_link);
        CVDisplayLinkRelease(p->display_link);
        p->display_link = NULL;
    }
    
    if (p->layer) {
        [p->layer removeFromSuperlayer];
        [p->layer release];
        p->layer = nil;
    }
    
    [p->vo_mac uninit:ctx->vo];
    
    ra_metal_destroy(ctx->ra);
    ctx->ra = NULL;
}

static void mac_metal_swap_buffers(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;
    
    if (p->current_drawable) {
        id<MTLCommandBuffer> command_buffer = [p->command_queue commandBuffer];
        [command_buffer presentDrawable:p->current_drawable];
        [command_buffer commit];
        [p->current_drawable release];
        p->current_drawable = nil;
    }
    
    [p->vo_mac swapBuffer];
}

static void mac_metal_get_vsync(struct ra_ctx *ctx, struct vo_vsync_info *info)
{
    struct priv *p = ctx->priv;
    [p->vo_mac fillVsyncWithInfo:info];
}

static int mac_metal_color_depth(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;
    
    // Check if we're using HDR
    if (@available(macOS 10.15, *)) {
        if (p->layer.wantsExtendedDynamicRangeContent) {
            return 10;
        }
    }
    
    return 8;
}

static bool mac_metal_check_visible(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;
    return [p->vo_mac isVisible];
}

static CVReturn display_link_callback(CVDisplayLinkRef display_link,
                                      const CVTimeStamp *now,
                                      const CVTimeStamp *output_time,
                                      CVOptionFlags flags_in,
                                      CVOptionFlags *flags_out,
                                      void *ctx_ptr)
{
    struct ra_ctx *ctx = ctx_ptr;
    struct priv *p = ctx->priv;
    
    p->vsync_info.vsync_duration = output_time->videoTime - now->videoTime;
    p->vsync_info.last_queue_display_time = output_time->hostTime;
    
    return kCVReturnSuccess;
}

static bool mac_metal_init(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv = talloc_zero(ctx, struct priv);
    
    // Create Metal device
    p->device = MTLCreateSystemDefaultDevice();
    if (!p->device) {
        MP_ERR(ctx, "Failed to create Metal device\n");
        return false;
    }
    
    // Create command queue
    p->command_queue = [p->device newCommandQueue];
    if (!p->command_queue) {
        MP_ERR(ctx, "Failed to create Metal command queue\n");
        return false;
    }
    
    // Initialize macOS common code
    p->vo_mac = [[MacCommon alloc] init:ctx->vo];
    if (!p->vo_mac) {
        MP_ERR(ctx, "Failed to initialize macOS common code\n");
        return false;
    }
    
    // Get or create CAMetalLayer
    p->layer = (CAMetalLayer *)p->vo_mac.layer;
    if (!p->layer || ![p->layer isKindOfClass:[CAMetalLayer class]]) {
        // Create new Metal layer if needed
        p->layer = [CAMetalLayer layer];
        p->layer.device = p->device;
        p->layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        p->layer.framebufferOnly = YES;
        
        // Handle HDR if available
        if (@available(macOS 10.15, *)) {
            p->layer.wantsExtendedDynamicRangeContent = YES;
            if (p->layer.wantsExtendedDynamicRangeContent) {
                p->layer.pixelFormat = MTLPixelFormatRGBA16Float;
                p->layer.colorspace = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
            }
        }
        
        // Replace the layer
        if (p->vo_mac.layer) {
            [p->vo_mac.layer removeFromSuperlayer];
        }
        p->vo_mac.layer = p->layer;
    }
    
    // Setup display link for vsync
    CVDisplayLinkCreateWithActiveCGDisplays(&p->display_link);
    CVDisplayLinkSetOutputCallback(p->display_link, display_link_callback, ctx);
    
    CGDirectDisplayID display_id = CGMainDisplayID();
    CVDisplayLinkSetCurrentCGDisplay(p->display_link, display_id);
    CVDisplayLinkStart(p->display_link);
    
    // Initialize Metal rendering abstraction
    ctx->ra = ra_metal_create(p->device, p->command_queue, ctx->log);
    if (!ctx->ra) {
        MP_ERR(ctx, "Failed to create Metal rendering abstraction\n");
        mac_metal_uninit(ctx);
        return false;
    }
    
    // Create swapchain
    struct ra_swapchain *sw = talloc_zero(ctx, struct ra_swapchain);
    sw->ctx = ctx;
    ctx->swapchain = sw;
    
    return true;
}

static bool mac_metal_reconfig(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;
    
    if (![p->vo_mac config:ctx->vo])
        return false;
    
    CGSize size = p->vo_mac.window.framePixel.size;
    p->layer.drawableSize = size;
    
    ctx->vo->dwidth = size.width;
    ctx->vo->dheight = size.height;
    
    return true;
}

static int mac_metal_control(struct ra_ctx *ctx, int *events, int request, void *arg)
{
    struct priv *p = ctx->priv;
    return [p->vo_mac control:ctx->vo events:events request:request data:arg];
}

const struct ra_ctx_fns ra_ctx_metal_mac = {
    .type           = "metal",
    .name           = "macmetal",
    .description    = "macOS/Metal",
    .reconfig       = mac_metal_reconfig,
    .control        = mac_metal_control,
    .init           = mac_metal_init,
    .uninit         = mac_metal_uninit,
};