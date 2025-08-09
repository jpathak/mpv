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

#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include "video/out/gpu/context.h"
#include "video/out/gpu/hwdec.h"
#include "osdep/ios/ios_common.h"
#include "ra_metal.h"

struct priv {
    struct ra_metal *ra_metal;
    UIView *view;
    CAMetalLayer *layer;
    id<MTLDevice> device;
    id<MTLCommandQueue> command_queue;
    id<CAMetalDrawable> current_drawable;
    CVDisplayLinkRef display_link;
    CADisplayLink *ca_display_link;
    struct vo_vsync_info vsync_info;
};

static void ios_metal_uninit(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;
    
    if (p->ca_display_link) {
        [p->ca_display_link invalidate];
        p->ca_display_link = nil;
    }
    
    if (p->layer) {
        [p->layer removeFromSuperlayer];
        p->layer = nil;
    }
    
    if (p->view) {
        [p->view release];
        p->view = nil;
    }
    
    ra_metal_destroy(ctx->ra);
    ctx->ra = NULL;
}

static void ios_metal_swap_buffers(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;
    
    if (p->current_drawable) {
        id<MTLCommandBuffer> command_buffer = [p->command_queue commandBuffer];
        [command_buffer presentDrawable:p->current_drawable];
        [command_buffer commit];
        p->current_drawable = nil;
    }
}

static void ios_metal_get_vsync(struct ra_ctx *ctx, struct vo_vsync_info *info)
{
    struct priv *p = ctx->priv;
    *info = p->vsync_info;
}

static int ios_metal_color_depth(struct ra_ctx *ctx)
{
    return 10; // iOS devices typically support 10-bit color
}

static bool ios_metal_check_visible(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;
    return p->view && p->view.window;
}

static void display_link_callback(CADisplayLink *display_link, void *ctx_ptr)
{
    struct ra_ctx *ctx = ctx_ptr;
    struct priv *p = ctx->priv;
    
    p->vsync_info.vsync_duration = display_link.duration * 1e9;
    p->vsync_info.last_queue_display_time = display_link.timestamp * 1e9;
}

static bool ios_metal_init(struct ra_ctx *ctx)
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
    
    // Create UIView if needed
    if (!ctx->vo->ios_view) {
        CGRect frame = [[UIScreen mainScreen] bounds];
        p->view = [[UIView alloc] initWithFrame:frame];
        p->view.backgroundColor = [UIColor blackColor];
    } else {
        p->view = ctx->vo->ios_view;
    }
    
    // Create and configure CAMetalLayer
    p->layer = [CAMetalLayer layer];
    p->layer.device = p->device;
    p->layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    p->layer.framebufferOnly = YES;
    p->layer.frame = p->view.bounds;
    p->layer.contentsScale = [[UIScreen mainScreen] scale];
    
    // Handle HDR if available
    if (@available(iOS 16.0, *)) {
        if (p->layer.wantsExtendedDynamicRangeContent) {
            p->layer.pixelFormat = MTLPixelFormatRGBA16Float;
            p->layer.colorspace = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
        }
    }
    
    [p->view.layer addSublayer:p->layer];
    
    // Create display link for vsync
    p->ca_display_link = [CADisplayLink displayLinkWithTarget:[NSBlockOperation blockOperationWithBlock:^{
        display_link_callback(p->ca_display_link, ctx);
    }] selector:@selector(main)];
    [p->ca_display_link addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
    
    // Initialize Metal rendering abstraction
    ctx->ra = ra_metal_create(p->device, p->command_queue, ctx->log);
    if (!ctx->ra) {
        MP_ERR(ctx, "Failed to create Metal rendering abstraction\n");
        ios_metal_uninit(ctx);
        return false;
    }
    
    // Create swapchain
    struct ra_swapchain *sw = talloc_zero(ctx, struct ra_swapchain);
    sw->ctx = ctx;
    ctx->swapchain = sw;
    
    struct ra_ctx_params params = {
        .swap_buffers = ios_metal_swap_buffers,
        .get_vsync = ios_metal_get_vsync,
        .color_depth = ios_metal_color_depth,
        .check_visible = ios_metal_check_visible,
    };
    
    return true;
}

static bool ios_metal_reconfig(struct ra_ctx *ctx)
{
    struct priv *p = ctx->priv;
    
    if (!p->view || !p->layer)
        return false;
    
    CGSize size = p->view.bounds.size;
    CGFloat scale = [[UIScreen mainScreen] scale];
    
    p->layer.drawableSize = CGSizeMake(size.width * scale, size.height * scale);
    p->layer.frame = p->view.bounds;
    
    ctx->vo->dwidth = size.width * scale;
    ctx->vo->dheight = size.height * scale;
    
    return true;
}

static int ios_metal_control(struct ra_ctx *ctx, int *events, int request, void *arg)
{
    struct priv *p = ctx->priv;
    
    switch (request) {
        case VOCTRL_CHECK_EVENTS:
            return VO_TRUE;
        case VOCTRL_GET_DISPLAY_FPS: {
            if (arg) {
                *(double *)arg = 60.0; // Default to 60 FPS, can be refined
                if (p->ca_display_link) {
                    *(double *)arg = 1.0 / p->ca_display_link.duration;
                }
            }
            return VO_TRUE;
        }
    }
    
    return VO_NOTIMPL;
}

const struct ra_ctx_fns ra_ctx_metal_ios = {
    .type           = "metal",
    .name           = "iosmetal",
    .description    = "iOS/Metal",
    .reconfig       = ios_metal_reconfig,
    .control        = ios_metal_control,
    .init           = ios_metal_init,
    .uninit         = ios_metal_uninit,
};