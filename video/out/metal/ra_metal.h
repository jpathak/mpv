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

#include "video/out/gpu/ra.h"
#include <Metal/Metal.h>

struct ra_metal {
    struct ra *ra;
    id<MTLDevice> device;
    id<MTLCommandQueue> command_queue;
};

struct ra *ra_metal_create(id<MTLDevice> device, id<MTLCommandQueue> queue, struct mp_log *log);
void ra_metal_destroy(struct ra *ra);

// Get the underlying Metal device from a ra instance
id<MTLDevice> ra_metal_get_device(const struct ra *ra);

// Get the current command buffer for rendering
id<MTLCommandBuffer> ra_metal_get_command_buffer(const struct ra *ra);

// Submit the current command buffer
void ra_metal_submit(const struct ra *ra);

// Check if ra is a Metal implementation
bool ra_is_metal(const struct ra *ra);

// Wrap an existing Metal texture
struct ra_tex *ra_metal_wrap_texture(struct ra *ra, id<MTLTexture> texture,
                                     const struct ra_tex_params *params);