/***************************************************************************
 # Copyright (c) 2015-21, NVIDIA CORPORATION. All rights reserved.
 #
 # Redistribution and use in source and binary forms, with or without
 # modification, are permitted provided that the following conditions
 # are met:
 #  * Redistributions of source code must retain the above copyright
 #    notice, this list of conditions and the following disclaimer.
 #  * Redistributions in binary form must reproduce the above copyright
 #    notice, this list of conditions and the following disclaimer in the
 #    documentation and/or other materials provided with the distribution.
 #  * Neither the name of NVIDIA CORPORATION nor the names of its
 #    contributors may be used to endorse or promote products derived
 #    from this software without specific prior written permission.
 #
 # THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS "AS IS" AND ANY
 # EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 # IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 # PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 # CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 # EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 # PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 # PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 # OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 # (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 # OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 **************************************************************************/

#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.RaytracingInline;
import Utils.Geometry.GeometryHelpers;

__exported import Scene.Shading;
__exported import Utils.Timing.GpuTimer;
__exported import Utils.Math.Ray;
import Utils.Math.MathHelpers;
import Utils.Sampling.TinyUniformSampleGenerator;

import Scene.SceneTypes;
import Scene.ShadingData;
import Rendering.Materials.IBSDF;
import Utils.Math.MathHelpers;
import Utils.Math.FormatConversion;
__exported import Scene.Material.ShadingUtils;
import Utils.Color.ColorHelpers;

import Reservoir;
import SurfaceData;
import HelperFunctions;
import LightSampler;


struct CreateDirectLightSamplesPass
{
	uint2   gFrameDim; ///< Frame dimensions.
	uint    gFrameCount; ///< Frame count since scene was loaded.

    // Resources:
    StructuredBuffer<PackedReservoir> gReservoirs; ///< Buffer with packed reservoirs.
    StructuredBuffer<PackedSurfaceData> gSurfaceData;
    RWStructuredBuffer<PackedDirectLightSample> gDirectLightSamples;

    LightSampler gLightSampler; ///< Custom light wrapper for sampling various kinds of lights (EmissiveGeometry, Environment, ...).

    // Debug:
    RWTexture2D<float4> gDebug;

	void execute(const uint2 pixel)
	{
	    if (any(pixel >= gFrameDim)) return;

		// Get index for the structured buffer access.
		uint bufferIndex = getBufferIndex(pixel, gFrameDim);

        // Create pixel Data for the current pixel.
        SurfaceData surfaceData = SurfaceData::unpack(gSurfaceData[bufferIndex]);
        if (!surfaceData.isValid()) return;

        Reservoir reservoir = Reservoir::unpack(gReservoirs[bufferIndex]);

        LightSample lightSample = gLightSampler.getLightSample(reservoir.sample);

        // VISUALIZE LIGHT INDEX
        // uint index = reservoir.sample.getIndex();
        // uint aliasTableSize = gLightSampler.emissiveGeometryAliasTable.count;
        // index = (index + 200) % aliasTableSize;
        // uint N = 3;
        // float index255 = 255.f * float(index) / float(aliasTableSize);
        // uint r = float(uint(index255) % N) / float(N - 1);
        // uint g = float(uint(index255 / float(N)) % N) / float(N - 1);
        // uint b = float(uint(index255 / float(N * N)) % N) / float(N - 1);
        // float gamma = 1.f / 2.2f;
        // gDebug[pixel] = float4(pow(float(r), gamma), pow(float(g), gamma), pow(float(b), gamma), 1);

        float3 rayOrigin = surfaceData.position;
        DirectLightSample outputSample = {};

        switch (lightSample.lightType)
        {
            case LightSample::Type::PointLight:
            case LightSample::Type::AreaLight:
            {
                float3 originToLight = lightSample.posDir - rayOrigin;
                outputSample.direction = normalize(originToLight);
                float distSqr = max(FLT_MIN, dot(originToLight, originToLight));
                float geometryFactor = max(0.f, dot(lightSample.normal, -outputSample.direction)) / distSqr;
                outputSample.distance = sqrt(distSqr);
                outputSample.Le = gLightSampler.getLightSampleRadiance(reservoir.sample) * reservoir.W * geometryFactor;
                break;
            }
            case LightSample::Type::DistantLight:
            {
                outputSample.direction = lightSample.posDir;
                outputSample.distance = lightSample.getDistanceToSample(rayOrigin);
                outputSample.Le = gLightSampler.getLightSampleRadiance(reservoir.sample) * reservoir.W;
                break;
            }
        }

        gDirectLightSamples[bufferIndex] = outputSample.pack();

    }
}

cbuffer CB
{
    CreateDirectLightSamplesPass gCreateDirectLightSamplesPass;
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId : SV_DispatchThreadID)
{
    gCreateDirectLightSamplesPass.execute(dispatchThreadId.xy);
}
