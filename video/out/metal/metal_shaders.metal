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

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

// Vertex data structure
struct VertexIn {
    float2 position [[attribute(0)]];
    float2 texcoord [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 texcoord;
};

// Basic vertex shader
vertex VertexOut vertex_basic(VertexIn in [[stage_in]],
                              constant float4x4& mvp [[buffer(0)]]) {
    VertexOut out;
    out.position = mvp * float4(in.position, 0.0, 1.0);
    out.texcoord = in.texcoord;
    return out;
}

// Fullscreen triangle vertex shader (no vertex buffer needed)
vertex VertexOut vertex_fullscreen(uint vid [[vertex_id]]) {
    VertexOut out;
    
    // Generate fullscreen triangle
    float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };
    
    float2 texcoords[3] = {
        float2(0.0, 1.0),
        float2(2.0, 1.0),
        float2(0.0, -1.0)
    };
    
    out.position = float4(positions[vid], 0.0, 1.0);
    out.texcoord = texcoords[vid];
    return out;
}

// Basic texture sampling fragment shader
fragment float4 fragment_texture(VertexOut in [[stage_in]],
                                 texture2d<float> tex [[texture(0)]],
                                 sampler samp [[sampler(0)]]) {
    return tex.sample(samp, in.texcoord);
}

// YUV to RGB conversion matrices
constant float3x3 yuv_to_rgb_bt601 = float3x3(
    float3(1.0,     1.0,    1.0),
    float3(0.0,    -0.344,  1.772),
    float3(1.402,  -0.714,  0.0)
);

constant float3x3 yuv_to_rgb_bt709 = float3x3(
    float3(1.0,     1.0,    1.0),
    float3(0.0,    -0.187,  1.856),
    float3(1.575,  -0.468,  0.0)
);

// YUV420 planar video rendering
fragment float4 fragment_yuv420(VertexOut in [[stage_in]],
                                texture2d<float> tex_y [[texture(0)]],
                                texture2d<float> tex_uv [[texture(1)]],
                                sampler samp [[sampler(0)]],
                                constant int& color_space [[buffer(0)]]) {
    float y = tex_y.sample(samp, in.texcoord).r;
    float2 uv = tex_uv.sample(samp, in.texcoord).rg;
    
    float3 yuv = float3(y, uv.x - 0.5, uv.y - 0.5);
    
    // Select color matrix based on color space
    float3x3 mat = (color_space == 0) ? yuv_to_rgb_bt601 : yuv_to_rgb_bt709;
    float3 rgb = mat * yuv;
    
    return float4(rgb, 1.0);
}

// Color correction shader
fragment float4 fragment_color_correct(VertexOut in [[stage_in]],
                                       texture2d<float> tex [[texture(0)]],
                                       sampler samp [[sampler(0)]],
                                       constant float& brightness [[buffer(0)]],
                                       constant float& contrast [[buffer(1)]],
                                       constant float& saturation [[buffer(2)]],
                                       constant float& gamma [[buffer(3)]]) {
    float4 color = tex.sample(samp, in.texcoord);
    
    // Apply brightness and contrast
    color.rgb = (color.rgb - 0.5) * contrast + 0.5 + brightness;
    
    // Apply saturation
    float luminance = dot(color.rgb, float3(0.299, 0.587, 0.114));
    color.rgb = mix(float3(luminance), color.rgb, saturation);
    
    // Apply gamma correction
    color.rgb = pow(color.rgb, float3(1.0 / gamma));
    
    return color;
}

// Simple OSD/subtitle overlay shader
fragment float4 fragment_overlay(VertexOut in [[stage_in]],
                                 texture2d<float> tex_video [[texture(0)]],
                                 texture2d<float> tex_overlay [[texture(1)]],
                                 sampler samp [[sampler(0)]]) {
    float4 video = tex_video.sample(samp, in.texcoord);
    float4 overlay = tex_overlay.sample(samp, in.texcoord);
    
    // Alpha blend overlay on top of video
    return mix(video, overlay, overlay.a);
}

// Compute shader for image processing (e.g., scaling, filtering)
kernel void compute_scale(texture2d<float, access::read> src [[texture(0)]],
                          texture2d<float, access::write> dst [[texture(1)]],
                          constant float2& scale [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]]) {
    // Check bounds
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) {
        return;
    }
    
    // Calculate source coordinates
    float2 src_coord = float2(gid) / scale;
    
    // Bilinear sampling
    uint2 src_size = uint2(src.get_width(), src.get_height());
    float2 texel = src_coord - 0.5;
    uint2 p0 = uint2(clamp(texel, float2(0), float2(src_size - 1)));
    uint2 p1 = uint2(clamp(texel + 1, float2(0), float2(src_size - 1)));
    
    float2 f = fract(texel);
    
    float4 c00 = src.read(uint2(p0.x, p0.y));
    float4 c10 = src.read(uint2(p1.x, p0.y));
    float4 c01 = src.read(uint2(p0.x, p1.y));
    float4 c11 = src.read(uint2(p1.x, p1.y));
    
    float4 result = mix(mix(c00, c10, f.x), mix(c01, c11, f.x), f.y);
    dst.write(result, gid);
}

// HDR tone mapping shader
fragment float4 fragment_hdr_tonemap(VertexOut in [[stage_in]],
                                     texture2d<float> tex [[texture(0)]],
                                     sampler samp [[sampler(0)]],
                                     constant float& exposure [[buffer(0)]],
                                     constant float& max_luminance [[buffer(1)]]) {
    float4 color = tex.sample(samp, in.texcoord);
    
    // Apply exposure
    color.rgb *= exposure;
    
    // Reinhard tone mapping
    float luminance = dot(color.rgb, float3(0.2126, 0.7152, 0.0722));
    float mapped_lum = luminance / (1.0 + luminance / max_luminance);
    color.rgb *= mapped_lum / luminance;
    
    // Gamma correction for display
    color.rgb = pow(color.rgb, float3(1.0 / 2.2));
    
    return color;
}

// Deinterlacing shader (bob method)
fragment float4 fragment_deinterlace(VertexOut in [[stage_in]],
                                     texture2d<float> tex [[texture(0)]],
                                     sampler samp [[sampler(0)]],
                                     constant int& field [[buffer(0)]]) {
    float2 coord = in.texcoord;
    float2 texel_size = 1.0 / float2(tex.get_width(), tex.get_height());
    
    // Adjust vertical coordinate based on field
    if (field == 0) {
        // Even field
        coord.y = coord.y * 0.5;
    } else {
        // Odd field
        coord.y = coord.y * 0.5 + 0.5;
    }
    
    return tex.sample(samp, coord);
}