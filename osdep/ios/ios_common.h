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

#include "video/out/vo.h"

struct vo_vsync_info {
    int64_t vsync_duration;
    int64_t skipped_vsyncs;
    int64_t last_queue_display_time;
};

// iOS view handle that can be stored in vo struct
struct vo {
    void *ios_view;  // UIView pointer
    int dwidth;
    int dheight;
    struct mp_log *log;
    struct mpv_global *global;
    void *input_ctx;
    // Add other necessary fields
};

// Swift bridge functions
void *ios_metal_layer_create(struct vo *vo);
void ios_metal_layer_destroy(void *common_ptr);
void *ios_metal_layer_get_metal_layer(void *common_ptr);