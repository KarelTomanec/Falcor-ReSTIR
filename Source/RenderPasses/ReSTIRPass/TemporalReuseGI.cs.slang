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

import ReservoirGI;
import SurfaceData;
import HelperFunctions;
import LightSampler;

struct TemporalReuseGIPass
{
	uint2   gFrameDim; ///< Frame dimensions.
	uint    gFrameCount; ///< Frame count since scene was loaded.

    LightSampler gLightSampler;

    // Resources:

	Texture2D<float2> gMotionVectors; ///< 2D screen space motion vector.

    StructuredBuffer<PackedSurfaceData> gSurfaceData;
    StructuredBuffer<PackedSurfaceData> gPrevSurfaceData;
	StructuredBuffer<PackedReservoirGI> gPrevGIReservoirs; ///< Buffer with packed reservoirs from the previous frame.
	RWStructuredBuffer<PackedReservoirGI> gGIReservoirs; ///< Buffer with packed reservoirs.

    // Debug:
    RWTexture2D<float4> gDebug;

    static const float kMaxOffset = 5.f;
    static const uint kAttemptCount = 1;

	void execute(const uint2 pixel)
	{
	    if (any(pixel >= gFrameDim)) return;

		// Get index for the structured buffer access.
		uint bufferIndex = getBufferIndex(pixel, gFrameDim);

		// Create sample generator.
		TinyUniformSampleGenerator sg = TinyUniformSampleGenerator(pixel, gFrameCount);

        // Get reservoir with initial candidate samples from the previous pass.
        ReservoirGI currentReservoir = ReservoirGI::unpack(gGIReservoirs[bufferIndex]);
        return;

        // Set history limit for the temporal reuse.
        uint historyLimit = TEMPORAL_MAX_HISTORY_LENGTH * currentReservoir.M;

        const float3 primaryRayOrigin = gScene.camera.getPosition();
        const float3 primaryRayDir = getPrimaryRayDir(pixel, gFrameDim, gScene.camera);
        const float3 viewVec = -normalize(primaryRayDir);

        // Reproject the pixel position.
        uint2 reprojPos = uint2(float2(pixel) + gMotionVectors[pixel] * gFrameDim + sampleNext2D(sg));

        // Get surface data for the current pixel.
        SurfaceData surfaceData = SurfaceData::unpack(gSurfaceData[bufferIndex]);
        if (!surfaceData.isValid())
            return;

        // ShadingData sdPrev;
        SurfaceData prevSurfaceData;
        uint2 prevPixel = reprojPos;
        bool neighborFound = false;


        [unroll]
        for (uint i = 0; i < kAttemptCount; i++)
        {
            int2 offset = int2(0, 0);
            if (i > 0) {

                offset.x = int((sampleNext1D(sg) - 0.5) * kMaxOffset);
                offset.y = int((sampleNext1D(sg) - 0.5) * kMaxOffset);
            }
            prevPixel = reprojPos + offset;

            // Test if previous pixel position is out of bounds.
            if (any(prevPixel >= gFrameDim) || any(prevPixel < 0))
                continue;

            // Load shading data for the previous pixel.
            prevSurfaceData = SurfaceData::unpack(gPrevSurfaceData[getBufferIndex(prevPixel, gFrameDim)]);
            if (!prevSurfaceData.isValid())
                continue;

            // Compare the difference in camera distance, and the angle between normals.
            if (!isValidNeighbor(surfaceData.normal, prevSurfaceData.normal, surfaceData.depth, prevSurfaceData.depth))
                continue;

            neighborFound = true;
            break;
		}

        if (!neighborFound)
            return;

        // Get index for the structured buffer access for the previous pixel.
        uint prevBufferIndex = getBufferIndex(prevPixel, gFrameDim);

        ReservoirGI outputReservoir;
        // Get final reservoir from the previous frame.
        ReservoirGI prevReservoir = ReservoirGI::unpack(gPrevGIReservoirs[prevBufferIndex]);

        // Clamp the previous frame's M.
        prevReservoir.M = min(historyLimit, prevReservoir.M);

        // Standard combination of multiple reservoirs reservoirs (Algorithm 4 from the original paper):
        SampleGI currSample = currentReservoir.sample;

        float targetPdf = luminance(currSample.Le);
        outputReservoir.update(currentReservoir, targetPdf, sg);
        float prevTargetPdf = luminance(prevReservoir.sample.Le);
        outputReservoir.update(prevReservoir, prevTargetPdf, sg);

        // outputReservoir.W = outputReservoir.W  > 0.f ? outputReservoir.weightSum / (outputReservoir.M * outputReservoir.W) : 0.f;
        outputReservoir.W = outputReservoir.W * outputReservoir.M > 0.f ? outputReservoir.weightSum / ( outputReservoir.M * outputReservoir.W) : 0.f;
        // outputReservoir.W = outputReservoir.W * Z > 0.f ? outputReservoir.weightSum / (Z * outputReservoir.W) : 0.f;

        // Store combined reservoir.
        outputReservoir.M = min(outputReservoir.M, 30);
        gGIReservoirs[bufferIndex] = outputReservoir.pack();

	}
}

cbuffer CB
{
    TemporalReuseGIPass gTemporalReuseGIPass;
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId : SV_DispatchThreadID)
{
    gTemporalReuseGIPass.execute(dispatchThreadId.xy);
}
