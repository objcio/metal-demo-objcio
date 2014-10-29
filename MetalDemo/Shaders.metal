//
//  Shaders.metal
//  MetalDemo
//
//  Created by Warren Moore on 10/28/14.
//  Copyright (c) 2014 objc.io. All rights reserved.
//

#include <metal_stdlib>
#include <simd/simd.h>

using namespace metal;

typedef struct
{
    matrix_float4x4 modelview_projection_matrix;
    matrix_float4x4 normal_matrix;
} uniforms_t;

typedef struct
{
    packed_float3 position;
    packed_float3 color;
} vertex_t;

typedef struct {
    float4 position [[position]];
    half4  color;
} ColorInOut;

vertex ColorInOut lighting_vertex(device vertex_t* vertex_array [[ buffer(0) ]],
                                  constant uniforms_t& uniforms [[ buffer(1) ]],
                                  unsigned int vid [[ vertex_id ]])
{
    ColorInOut out;

    float4 in_position = float4(float3(vertex_array[vid].position), 1.0);
    out.position = uniforms.modelview_projection_matrix * in_position;
    
    float4 color = float4(vertex_array[vid].color, 1);
    out.color = half4(color);
    
    return out;
}

fragment half4 lighting_fragment(ColorInOut in [[stage_in]])
{
    return in.color;
}
