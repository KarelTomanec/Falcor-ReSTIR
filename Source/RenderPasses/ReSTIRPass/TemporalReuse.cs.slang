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

struct TemporalReusePass
{
	uint2   gFrameDim; ///< Frame dimensions.
	uint    gFrameCount; ///< Frame count since scene was loaded.

    LightSampler gLightSampler;

    // Resources:

	Texture2D<float2> gMotionVectors; ///< 2D screen space motion vector.
	Texture2D<PackedHitInfo> gVBuffer; ///< Fullscreen V-buffer for the primary hits.

    StructuredBuffer<PackedSurfaceData> gSurfaceData;
    RWStructuredBuffer<PackedNormalDepth> gNormalDepth;

    StructuredBuffer<PackedSurfaceData> gPrevSurfaceData;
    RWStructuredBuffer<PackedNormalDepth> gPrevNormalDepth;
	StructuredBuffer<PackedReservoir> gPrevReservoirs; ///< Buffer with packed reservoirs from the previous frame.
	RWStructuredBuffer<PackedReservoir> gReservoirs; ///< Buffer with packed reservoirs.

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
		Reservoir currentReservoir = Reservoir::unpack(gReservoirs[bufferIndex]);

        // Set history limit for the temporal reuse.
        uint historyLimit = TEMPORAL_MAX_HISTORY_LENGTH * currentReservoir.M;

        const float3 primaryRayOrigin = gScene.camera.getPosition();
        const float3 primaryRayDir = getPrimaryRayDir(pixel, gFrameDim, gScene.camera);
        const float3 viewVec = -normalize(primaryRayDir);

        // gDebug[pixel] = float4(gPrevNormalDepth[bufferIndex], 1);

        // Reproject the pixel position.
        uint2 reprojPos = uint2(float2(pixel) + gMotionVectors[pixel] * gFrameDim + sampleNext2D(sg));
        uint2 prevPixel = reprojPos;

        NormalDepth normalDepth = NormalDepth::unpack(gNormalDepth[bufferIndex]);
        if (!normalDepth.isValid())
            return;

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

            NormalDepth prevNormalDepth = NormalDepth::unpack(gPrevNormalDepth[getBufferIndex(prevPixel, gFrameDim)]);
            if (!prevNormalDepth.isValid())
                return;

            // Compare the difference in camera distance, and the angle between normals.
            if (!isValidNeighbor(normalDepth.normal, prevNormalDepth.normal, normalDepth.depth, prevNormalDepth.depth)) continue;

            neighborFound = true;
            break;
        }

        if (!neighborFound)
            return;

        // Get index for the structured buffer access for the previous pixel.
        uint prevBufferIndex = getBufferIndex(prevPixel, gFrameDim);

		// Get final reservoir from the previous frame.
		Reservoir prevReservoir = Reservoir::unpack(gPrevReservoirs[prevBufferIndex]);

        // Clamp the previous frame's M.
        prevReservoir.M = min(historyLimit, prevReservoir.M);

        // Create output reservoir.
        Reservoir outputReservoir;

        // Get surface data for the current pixel.
        SurfaceData surfaceData = SurfaceData::unpack(gSurfaceData[bufferIndex]);

        // Load shading data for the previous pixel.
        SurfaceData prevSurfaceData = SurfaceData::unpack(gPrevSurfaceData[getBufferIndex(prevPixel, gFrameDim)]);

#if BIASED

        // Standard combination of multiple reservoirs reservoirs (Algorithm 4 from the original paper):
        LightSample currLightSample = gLightSampler.getLightSample(currentReservoir.sample);
        float currReservoirTargetPDF = surfaceData.evalTargetPDF(currLightSample, viewVec);
        outputReservoir.update(currentReservoir, currReservoirTargetPDF, sg);

        LightSample prevLightSample = gLightSampler.getLightSample(prevReservoir.sample);
        float prevReservoirTargetPDF = surfaceData.evalTargetPDF(prevLightSample, viewVec);
        outputReservoir.update(prevReservoir, prevReservoirTargetPDF, sg);

		outputReservoir.W = outputReservoir.W > 0.f ? (outputReservoir.weightSum / outputReservoir.M) / outputReservoir.W : 0.f;

#elif UNBIASED_NAIVE

        // Naive unbiased combination of multiple reservoirs (Algorithm 6 from the original ReSTIR paper):
        LightSample currLightSample = gLightSampler.getLightSample(currentReservoir.sample);
        float currReservoirTargetPDF = surfaceData.evalTargetPDF(currLightSample, viewVec);
        outputReservoir.update(currentReservoir, currReservoirTargetPDF, sg);

        LightSample prevLightSample = gLightSampler.getLightSample(prevReservoir.sample);
        float prevReservoirTargetPDF = surfaceData.evalTargetPDF(prevLightSample, viewVec);
        outputReservoir.update(prevReservoir, prevReservoirTargetPDF, sg);

        float Z = 0.f;
        LightSample outputLightSample = gLightSampler.getLightSample(outputReservoir.sample);
        if (surfaceData.evalTargetPDF(outputLightSample, viewVec))
        {
            Z += currentReservoir.M;
        }
        if (prevSurfaceData.evalTargetPDF(outputLightSample, viewVec))
        {
            Z += prevReservoir.M;
		}

		float m = 1.f / Z;
		outputReservoir.W = (outputReservoir.W > 0.f && !isinf(m)) ? (outputReservoir.weightSum * m) / outputReservoir.W : 0.f;

#elif UNBIASED_MIS

		// Unbiased combination of multiple reservoirs using MIS (Algorithm 1 from the original ReSTIR paper's supplemental document):
        LightSample currLightSample = gLightSampler.getLightSample(currentReservoir.sample);
        float currReservoirTargetPDF = surfaceData.evalTargetPDF(currLightSample, viewVec);
#if UNBIASED_RAYTRACED
        currReservoirTargetPDF *= surfaceData.evalVisibility(currLightSample);
#endif
        outputReservoir.update(currentReservoir, currReservoirTargetPDF, sg);

        LightSample prevLightSample = gLightSampler.getLightSample(prevReservoir.sample);
        float prevReservoirTargetPDF = surfaceData.evalTargetPDF(prevLightSample, viewVec);
#if UNBIASED_RAYTRACED
        prevReservoirTargetPDF *= surfaceData.evalVisibility(prevLightSample);
#endif
        bool neighborContributed = outputReservoir.update(prevReservoir, prevReservoirTargetPDF, sg);

        LightSample outputLightSample = gLightSampler.getLightSample(outputReservoir.sample);
		float pSum = 0.f;

        float currPixelTargetPDF = surfaceData.evalTargetPDF(outputLightSample, viewVec);
#if UNBIASED_RAYTRACED
        currPixelTargetPDF *= surfaceData.evalVisibility(outputLightSample);
#endif
        pSum += currPixelTargetPDF * currentReservoir.M;

        float prevPixelTargetPDF = prevSurfaceData.evalTargetPDF(outputLightSample, viewVec);
#if UNBIASED_RAYTRACED
        prevPixelTargetPDF *= surfaceData.evalVisibility(outputLightSample);
#endif
        pSum += prevPixelTargetPDF * prevReservoir.M;

        float m = pSum > 0.f ? ((neighborContributed ? prevPixelTargetPDF : currPixelTargetPDF) / pSum) : 0.f;
        outputReservoir.W = outputReservoir.W > 0.f ? (outputReservoir.weightSum * m) / outputReservoir.W : 0.f;
#endif

		// Store combined reservoir.
		gReservoirs[bufferIndex] = outputReservoir.pack();

	}
}

cbuffer CB
{
	TemporalReusePass gTemporalReusePass;
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId : SV_DispatchThreadID)
{
	gTemporalReusePass.execute(dispatchThreadId.xy);
}
