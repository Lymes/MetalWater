//
//  Acqua.metal
//  MetalAcqua
//
//  Created by Leonid Mesentsev on 18/11/2018.
//  Copyright © 2018 Bridge Comm. All rights reserved.
//

#include <metal_stdlib>
using namespace metal;



typedef struct
{
    int touchRadius;
    float2 location;
    ushort poolWidth;
    ushort poolHeight;
    float  texCoordFactorS;
    float  texCoordOffsetS;
    float  texCoordFactorT;
    float  texCoordOffsetT;
}
ModelData;




void initiateRipple(
                    device ModelData *modelData,
                    device float     *rippleSource,
                    device float     *rippleCoeff
)
{
    unsigned int xIndex = (unsigned int)(modelData->location.x * modelData->poolWidth);
    unsigned int yIndex = (unsigned int)(modelData->location.y * modelData->poolHeight);

    for ( int y = (int)yIndex - (int)modelData->touchRadius; y <= (int)yIndex + (int)modelData->touchRadius; y++ )
    {
        for ( int x = (int)xIndex - (int)modelData->touchRadius; x <= (int)xIndex + (int)modelData->touchRadius; x++ )
        {
            if ( x >= 0 && x < modelData->poolWidth &&
                y >= 0 && y < modelData->poolHeight )
            {
                // +1 to both x/y values because the border is padded
                rippleSource[(modelData->poolWidth + 2) * (y + 1) + x + 1] += rippleCoeff[(y - (yIndex - modelData->touchRadius)) * (modelData->touchRadius * 2 + 1) + x - (xIndex - modelData->touchRadius)];
            }
        }
    }
}



kernel void runSimulation(
                          device float2    *texCoords       [[ buffer(0) ]],
                          device ModelData *modelData       [[ buffer(1) ]],
                          device float     *rippleDest      [[ buffer(2) ]],
                          device float     *rippleSource    [[ buffer(3) ]],
                          device float     *rippleCoeff     [[ buffer(4) ]],
                          uint2            gid              [[thread_position_in_grid]])
{
    
    if ( modelData->location.x != 0 && modelData->location.y != 0 )
    {
        initiateRipple(modelData, rippleSource, rippleCoeff);
        modelData->location.x = 0;
        modelData->location.y = 0;
    }
    
    for ( int y = 0; y < modelData->poolHeight; y++ )
    {
        for ( int x = 0; x < modelData->poolWidth; x++ )
        {
            // * - denotes current pixel
            //
            //       a
            //     c * d
            //       b
            
            // +1 to both x/y values because the border is padded
            float a = rippleSource[(y + 0) * (modelData->poolWidth + 2) + x + 1];
            float b = rippleSource[(y + 2) * (modelData->poolWidth + 2) + x + 1];
            float c = rippleSource[(y + 1) * (modelData->poolWidth + 2) + x + 0];
            float d = rippleSource[(y + 1) * (modelData->poolWidth + 2) + x + 2];
            
            float result = (a + b + c + d) / 2.f - rippleDest[(y + 1) * (modelData->poolWidth + 2) + x + 1];
            
            result -= (result / 32.f);
            
            rippleDest[(y + 1) * (modelData->poolWidth + 2) + x + 1] = result;
        }
    }
    
    for ( int y = 0; y < modelData->poolHeight; y++ )
    {
        for ( int x = 0; x < modelData->poolWidth; x++ )
        {
            // * - denotes current pixel
            //
            //       a
            //     c * d
            //       b
            
            // +1 to both x/y values because the border is padded
            float a = rippleDest[(y + 0) * (modelData->poolWidth + 2) + x + 1];
            float b = rippleDest[(y + 2) * (modelData->poolWidth + 2) + x + 1];
            float c = rippleDest[(y + 1) * (modelData->poolWidth + 2) + x + 0];
            float d = rippleDest[(y + 1) * (modelData->poolWidth + 2) + x + 2];
            
            float s_offset = ((b - a) / 2048.f);
            float t_offset = ((c - d) / 2048.f);
            
            // clamp
            s_offset = (s_offset < -0.5f) ? -0.5f : s_offset;
            t_offset = (t_offset < -0.5f) ? -0.5f : t_offset;
            s_offset = (s_offset >  0.5f) ?  0.5f : s_offset;
            t_offset = (t_offset >  0.5f) ?  0.5f : t_offset;
            
            float s_tc = (float)y / (modelData->poolHeight - 1) * modelData->texCoordFactorS + modelData->texCoordOffsetS;
            float t_tc = (1.f - (float)x / (modelData->poolWidth - 1)) * modelData->texCoordFactorT + modelData->texCoordOffsetT;
            
            int index = y * modelData->poolWidth + x;
            texCoords[index].x = s_tc + s_offset;
            texCoords[index].y = t_tc + t_offset;
        }
    }
}



typedef struct
{
    float4 renderedCoordinate [[position]];
    float2 textureCoordinate;
}
TextureMappingVertex;


vertex TextureMappingVertex vertexTexture(
                                          const device float2    *positions    [[ buffer(0) ]],
                                          const device float2    *texCoords    [[ buffer(1) ]],
                                          unsigned     int        vertex_id    [[ vertex_id ]])
{
    TextureMappingVertex outVertex;
    outVertex.renderedCoordinate = float4(positions[vertex_id], 0, 1);
    outVertex.textureCoordinate = texCoords[vertex_id];
    return outVertex;
}


fragment half4 fragmentTexture(TextureMappingVertex mappingVertex [[ stage_in ]],
                                    texture2d<float, access::sample> texture [[ texture(0) ]]) {
    constexpr sampler s(address::clamp_to_edge, filter::linear);
//    constexpr sampler s(address::repeat, filter::linear);
    return half4(texture.sample(s, mappingVertex.textureCoordinate));
}

