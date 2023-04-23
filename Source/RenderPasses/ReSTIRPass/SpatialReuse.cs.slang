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


struct SpatialReusePass
{
	uint2   gFrameDim; ///< Frame dimensions.
	uint    gFrameCount; ///< Frame count since scene was loaded.

    LightSampler gLightSampler;

	// Resources:
    StructuredBuffer<PackedReservoir> gReservoirs; ///< Buffer with packed reservoirs.
    StructuredBuffer<PackedSurfaceData> gSurfaceData;
    StructuredBuffer<PackedNormalDepth> gNormalDepth;
	RWStructuredBuffer<PackedReservoir> gOutReservoirs; ///< Output buffer with packed reservoirs.

    // Debug:
    RWTexture2D<float4> gDebug;

	void execute(const uint2 pixel)
	{
	    if (any(pixel >= gFrameDim))
            return;

		// Get index for the structured buffer access.
		uint bufferIndex = getBufferIndex(pixel, gFrameDim);

		// Create sample generator.
		TinyUniformSampleGenerator sg = TinyUniformSampleGenerator(pixel, gFrameCount);

        // Get reservoir with initial candidate samples from the previous pass.
        Reservoir currentReservoir = Reservoir::unpack(gReservoirs[bufferIndex]);

		// Create output reservoir.
		Reservoir outputReservoir;

        const float3 primaryRayOrigin = gScene.camera.getPosition();
        const float3 primaryRayDir = getPrimaryRayDir(pixel, gFrameDim, gScene.camera);
        const float3 viewVec = -normalize(primaryRayDir);

        // Get pixel Data for the current pixel.
        NormalDepth normalDepth = NormalDepth::unpack(gNormalDepth[bufferIndex]);
        if (!normalDepth.isValid())
            return;
        SurfaceData surfaceData = SurfaceData::unpack(gSurfaceData[bufferIndex]);
        if (!surfaceData.isValid())
            return;

        LightSample currLightSample = gLightSampler.getLightSample(currentReservoir.sample);
        float currReservoirTargetPDF = surfaceData.evalTargetPDF(currLightSample, viewVec);
        outputReservoir.update(currentReservoir, currReservoirTargetPDF, sg);

        uint validNeighborFlags = 0;

#if BIASED
		[unroll]
		for(int i = 0; i < SPATIAL_REUSE_SAMPLE_COUNT; i++)
		{
            uint2 neighborPixel = getRandomNeighborPixel(pixel, sg);

			// Discard pixel if out of bounds
			if(any(neighborPixel >= gFrameDim) || any(neighborPixel < 0))
                continue;

			uint neighborBufferIndex = getBufferIndex(neighborPixel, gFrameDim);
			Reservoir neighborReservoir = Reservoir::unpack(gReservoirs[neighborBufferIndex]);

            if (neighborReservoir.M == 0.f)
                continue;

            NormalDepth neighborNormalDepth = NormalDepth::unpack(gNormalDepth[neighborBufferIndex]);
            if (!neighborNormalDepth.isValid())
                return;

            if (!isValidNeighbor(normalDepth.normal, neighborNormalDepth.normal, normalDepth.depth, neighborNormalDepth.depth))
                continue;

            SurfaceData neighborSurfaceData = SurfaceData::unpack(gSurfaceData[neighborBufferIndex]);

            LightSample neighborLightSample = gLightSampler.getLightSample(neighborReservoir.sample);
            float neighborReservoirTargetPDF = surfaceData.evalTargetPDF(neighborLightSample, viewVec);
            outputReservoir.update(neighborReservoir, neighborReservoirTargetPDF, sg);
		}

		outputReservoir.W = outputReservoir.W > 0.f ? (outputReservoir.weightSum / outputReservoir.M ) / outputReservoir.W : 0.f;
#elif UNBIASED_NAIVE
		TinyUniformSampleGenerator sg1 = sg;
		TinyUniformSampleGenerator sg2 = sg;
		[unroll]
        for (int i = 0; i < SPATIAL_REUSE_SAMPLE_COUNT; i++)
        {
            uint2 neighborPixel = getRandomNeighborPixel(pixel, sg1);

			// Discard pixel if out of bounds
			if(any(neighborPixel >= gFrameDim) || any(neighborPixel < 0))
                continue;

            uint neighborBufferIndex = getBufferIndex(neighborPixel, gFrameDim);
            Reservoir neighborReservoir = Reservoir::unpack(gReservoirs[neighborBufferIndex]);

            if (neighborReservoir.M == 0.f)
                continue;

            NormalDepth neighborNormalDepth = NormalDepth::unpack(gNormalDepth[neighborBufferIndex]);
            if (!neighborNormalDepth.isValid())
                return;

            if (!isValidNeighbor(normalDepth.normal, neighborNormalDepth.normal, normalDepth.depth, neighborNormalDepth.depth))
                continue;

            SurfaceData neighborSurfaceData = SurfaceData::unpack(gSurfaceData[neighborBufferIndex]);

            LightSample neighborLightSample = gLightSampler.getLightSample(neighborReservoir.sample);
            float neighborReservoirTargetPDF = surfaceData.evalTargetPDF(neighborLightSample, viewVec);
            outputReservoir.update(neighborReservoir, neighborReservoirTargetPDF, sg);

            validNeighborFlags |= 1 << i;
		}

        float Z = 0.f;
        LightSample outputLightSample = gLightSampler.getLightSample(outputReservoir.sample);
        if (surfaceData.evalTargetPDF(outputLightSample, viewVec))
        {
            Z += currentReservoir.M;
		}

		[unroll]
        for (int i = 0; i < SPATIAL_REUSE_SAMPLE_COUNT; i++)
        {
            if (!(validNeighborFlags & 1 << i))
                continue;

            uint2 neighborPixel = getRandomNeighborPixel(pixel, sg2);

            uint neighborBufferIndex = getBufferIndex(neighborPixel, gFrameDim);
            Reservoir neighborReservoir = Reservoir::unpack(gReservoirs[neighborBufferIndex]);

            SurfaceData neighborSurfaceData = SurfaceData::unpack(gSurfaceData[neighborBufferIndex]);

            if (neighborSurfaceData.evalTargetPDF(outputLightSample, viewVec))
                Z += neighborReservoir.M;
        }
        float m = 1.f / Z;
        outputReservoir.W = (outputReservoir.W > 0.f && !isinf(m)) ? (outputReservoir.weightSum * m) / outputReservoir.W : 0.f;

#elif UNBIASED_MIS
		int selectedSample = -1;
		TinyUniformSampleGenerator sg1 = sg;
		TinyUniformSampleGenerator sg2 = sg;
		[unroll]
        for (int i = 0; i < SPATIAL_REUSE_SAMPLE_COUNT; i++)
        {
            uint2 neighborPixel = getRandomNeighborPixel(pixel, sg1);

			// Discard pixel if out of bounds
			if(any(neighborPixel >= gFrameDim) || any(neighborPixel < 0))
                continue;

            uint neighborBufferIndex = getBufferIndex(neighborPixel, gFrameDim);
            Reservoir neighborReservoir = Reservoir::unpack(gReservoirs[neighborBufferIndex]);

            if (neighborReservoir.M == 0.f)
                continue;

            NormalDepth neighborNormalDepth = NormalDepth::unpack(gNormalDepth[neighborBufferIndex]);
            if (!neighborNormalDepth.isValid())
                return;

            if (!isValidNeighbor(normalDepth.normal, neighborNormalDepth.normal, normalDepth.depth, neighborNormalDepth.depth))
                continue;

            SurfaceData neighborSurfaceData = SurfaceData::unpack(gSurfaceData[neighborBufferIndex]);

            LightSample neighborLightSample = gLightSampler.getLightSample(neighborReservoir.sample);
            float neighborReservoirTargetPDF = surfaceData.evalTargetPDF(neighborLightSample, viewVec);

            if (outputReservoir.update(neighborReservoir, neighborReservoirTargetPDF, sg))
                selectedSample = i;

            validNeighborFlags |= 1 << i;
		}

        LightSample outputLightSample = gLightSampler.getLightSample(outputReservoir.sample);
        float currPixelTargetPDF = surfaceData.evalTargetPDF(outputLightSample, viewVec);

        float visibleSelected = 1.f;
#if UNBIASED_RAYTRACED
        visibleSelected = surfaceData.evalVisibility(outputLightSample);
        currPixelTargetPDF *= visibleSelected;
#endif
        float pSum = visibleSelected * currentReservoir.M * outputReservoir.W;
		float pStar = 0.f;
		if(selectedSample == -1)
            pStar = currPixelTargetPDF;

        if (visibleSelected)
        {
            [unroll]
            for (int i = 0; i < SPATIAL_REUSE_SAMPLE_COUNT; i++)
            {
                if (!(validNeighborFlags & 1 << i))
                    continue;

                uint2 neighborPixel = getRandomNeighborPixel(pixel, sg2);

                uint neighborBufferIndex = getBufferIndex(neighborPixel, gFrameDim);
                Reservoir neighborReservoir = Reservoir::unpack(gReservoirs[neighborBufferIndex]);

                SurfaceData neighborSurfaceData = SurfaceData::unpack(gSurfaceData[neighborBufferIndex]);

                float neighborPixelTargetPDF = neighborSurfaceData.evalTargetPDF(outputLightSample, viewVec);
#if UNBIASED_RAYTRACED
                neighborPixelTargetPDF *= neighborSurfaceData.evalVisibility(outputLightSample);
#endif
                pSum += neighborPixelTargetPDF * neighborReservoir.M;
                if (selectedSample == i)
                    pStar = neighborPixelTargetPDF;
            }
        }

        float m = pSum > 0.f ? pStar / pSum : 0.f;
        outputReservoir.W = outputReservoir.W > 0.f ? (outputReservoir.weightSum * m) / outputReservoir.W : 0.f;
#endif
		// Store reservoir
		gOutReservoirs[bufferIndex] = outputReservoir.pack();
	}
}

cbuffer CB
{
	SpatialReusePass gSpatialReusePass;
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId : SV_DispatchThreadID)
{
    gSpatialReusePass.execute(dispatchThreadId.xy);
}
