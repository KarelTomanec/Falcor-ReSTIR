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

	// Inputs
    StructuredBuffer<PackedReservoir> gReservoirs; ///< Buffer with packed reservoirs.
    StructuredBuffer<PackedSurfaceData> gSurfaceData;

	// Outputs
	RWStructuredBuffer<PackedReservoir> gOutReservoirs; ///< Output buffer with packed reservoirs.

    uint2 getRandomNeighborPixel<S : ISampleGenerator>(uint2 pixel, inout S sg)
    {
        float rho = SPATIAL_REUSE_SAMPLE_RADIUS * sqrt(sampleNext1D(sg));
        float theta = 2.0f * M_PI * sampleNext1D(sg);
        float2 randomPixel = pixel;
        randomPixel.x += rho * cos(theta);
        randomPixel.y += rho * sin(theta);

        return uint2(round(randomPixel));
	}

	void execute(const uint2 pixel)
	{
	    if (any(pixel >= gFrameDim)) return;

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

        // Create pixel Data for the current pixel.
        SurfaceData surfaceData = SurfaceData::unpack(gSurfaceData[bufferIndex]);

        const float distCurrent = distance(surfaceData.position, primaryRayOrigin);

        LightSample currLightSample = gLightSampler.getLightSample(currentReservoir.sample);
        float currReservoirTargetPDF = surfaceData.evalTargetPDF(currLightSample, viewVec, sg);
        outputReservoir.update(currentReservoir, currReservoirTargetPDF, sg);

#if BIASED
		[unroll]
		for(int i = 0; i < SPATIAL_REUSE_SAMPLE_COUNT; i++)
		{
            uint2 neighborPixel = getRandomNeighborPixel(pixel, sg);

			// Discard pixel if out of bounds
			if(any(neighborPixel >= gFrameDim) || any(neighborPixel < 0)) continue;

			uint neighborBufferIndex = getBufferIndex(neighborPixel, gFrameDim);
			Reservoir neighborReservoir = Reservoir::unpack(gReservoirs[neighborBufferIndex]);

            if (neighborReservoir.M == 0.f) continue;

            const float3 primaryRayDirNeighbor = getPrimaryRayDir(neighborPixel, gFrameDim, gScene.camera);
            SurfaceData neighborSurfaceData = SurfaceData::unpack(gSurfaceData[neighborBufferIndex]);
            const float distNeighbor = distance(neighborSurfaceData.position, primaryRayOrigin);

            if (!isValidNeighbor(surfaceData.normal, neighborSurfaceData.normal, distCurrent, distNeighbor)) continue;

            LightSample neighborLightSample = gLightSampler.getLightSample(neighborReservoir.sample);
            float neighborReservoirTargetPDF = surfaceData.evalTargetPDF(neighborLightSample, viewVec, sg);
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
			if(any(neighborPixel >= gFrameDim) || any(neighborPixel < 0)) continue;

            uint neighborBufferIndex = getBufferIndex(neighborPixel, gFrameDim);
            Reservoir neighborReservoir = Reservoir::unpack(gReservoirs[neighborBufferIndex]);

            if (neighborReservoir.M == 0.f) continue;

            const float3 primaryRayDirNeighbor = getPrimaryRayDir(neighborPixel, gFrameDim, gScene.camera);
            SurfaceData neighborSurfaceData = SurfaceData::unpack(gSurfaceData[neighborBufferIndex]);
            const float distNeighbor = distance(neighborSurfaceData.position, primaryRayOrigin);

            if (!isValidNeighbor(surfacemData.normal, neighborSurfaceData.normal, distCurrent, distNeighbor)) continue;

            LightSample neighborLightSample = gLightSampler.getLightSample(neighborReservoir.sample);
            float neighborReservoirTargetPDF = surfaceData.evalTargetPDF(neighborLightSample, viewVec, sg);
            outputReservoir.update(neighborReservoir, neighborReservoirTargetPDF, sg);
		}

        float Z = 0.f;
        LightSample outputLightSample = gLightSampler.getLightSample(outputReservoir.sample);
        if (surfaceData.evalTargetPDF(outputLightSample, viewVec, sg))
        {
            Z += currentReservoir.M;
		}

		[unroll]
        for (int i = 0; i < SPATIAL_REUSE_SAMPLE_COUNT; i++)
        {
            uint2 neighborPixel = getRandomNeighborPixel(pixel, sg2);

			// Discard pixel if out of bounds
			if(any(neighborPixel >= gFrameDim) || any(neighborPixel < 0)) continue;

            uint neighborBufferIndex = getBufferIndex(neighborPixel, gFrameDim);
            Reservoir neighborReservoir = Reservoir::unpack(gReservoirs[neighborBufferIndex]);

            if (neighborReservoir.M == 0.f) continue;

            const float3 primaryRayDirNeighbor = getPrimaryRayDir(neighborPixel, gFrameDim, gScene.camera);
            SurfaceData neighborSurfaceData = SurfaceData::unpack(gSurfaceData[neighborBufferIndex]);
            const float distNeighbor = distance(neighborSurfaceData.position, primaryRayOrigin);

            if (!isValidNeighbor(surfaceData.normal, neighborSurfaceData.normal, distCurrent, distNeighbor)) continue;

            if (neighborSurfaceData.evalTargetPDF(outputLightSample, viewVec, sg))
            {
                Z += neighborReservoir.M;
			}
		}

		float m = 1.f / Z;
		outputReservoir.W = outputReservoir.W > 0.f ? (outputReservoir.weightSum * m) / outputReservoir.W : 0.f;

#elif UNBIASED_MIS
		int selectedSample = -1;
		TinyUniformSampleGenerator sg1 = sg;
		TinyUniformSampleGenerator sg2 = sg;
		[unroll]
        for (int i = 0; i < SPATIAL_REUSE_SAMPLE_COUNT; i++)
        {
            uint2 neighborPixel = getRandomNeighborPixel(pixel, sg1);

			// Discard pixel if out of bounds
			if(any(neighborPixel >= gFrameDim) || any(neighborPixel < 0)) continue;

            uint neighborBufferIndex = getBufferIndex(neighborPixel, gFrameDim);
            Reservoir neighborReservoir = Reservoir::unpack(gReservoirs[neighborBufferIndex]);

            if (neighborReservoir.M == 0.f) continue;

            const float3 primaryRayDirNeighbor = getPrimaryRayDir(neighborPixel, gFrameDim, gScene.camera);
            SurfaceData neighborSurfaceData = SurfaceData::unpack(gSurfaceData[neighborBufferIndex]);
            SurfaceData neighborSurfaceData = SurfaceData::unpack(gSurfaceData[neighborBufferIndex]);
            const float distNeighbor = distance(neighborSurfaceData.position, primaryRayOrigin);

            if (!isValidNeighbor(surfaceData.normal, neighborSurfaceData.normal, distCurrent, distNeighbor)) continue;

            LightSample neighborLightSample = gLightSampler.getLightSample(neighborReservoir.sample);
            float neighborReservoirTargetPDF = surfaceData.evalTargetPDF(neighborLightSample, viewVec, sg);
            if (outputReservoir.update(neighborReservoir, neighborReservoirTargetPDF, sg))
			{
				selectedSample = i;
			}
		}

        float pSum = 0.f;
        LightSample outputLightSample = gLightSampler.getLightSample(outputReservoir.sample);
        float currPixelTargetPDF = surfaceData.evalTargetPDF(outputLightSample, viewVec, sg);
        pSum += currPixelTargetPDF * currentReservoir.M;
		float pStar;
		if(selectedSample == -1)
		{
			pStar = currPixelTargetPDF;
		}

		[unroll]
        for (int i = 0; i < SPATIAL_REUSE_SAMPLE_COUNT; i++)
        {
            uint2 neighborPixel = getRandomNeighborPixel(pixel, sg2);

			// Discard pixel if out of bounds
			if(any(neighborPixel >= gFrameDim) || any(neighborPixel < 0)) continue;

            uint neighborBufferIndex = getBufferIndex(neighborPixel, gFrameDim);
            Reservoir neighborReservoir = Reservoir::unpack(gReservoirs[neighborBufferIndex]);

            if (neighborReservoir.M == 0.f) continue;

            const float3 primaryRayDirNeighbor = getPrimaryRayDir(neighborPixel, gFrameDim, gScene.camera);
            SurfaceData neighborSurfaceData = SurfaceData::unpack(gSurfaceData[neighborBufferIndex]);
            const float distNeighbor = distance(neighborSurfaceData.position, primaryRayOrigin);

            if (!isValidNeighbor(surfaceData.normal, neighborSurfaceData.normal, distCurrent, distNeighbor)) continue;

            LightSample neighborLightSample = gLightSampler.getLightSample(neighborReservoir.sample);
            float neighborPixelTargetPDF = neighborSurfaceData.evalTargetPDF(neighborLightSample, viewVec, sg);
            pSum += neighborPixelTargetPDF * neighborReservoir.M;
			if(selectedSample == i) {
				pStar = neighborPixelTargetPDF;
			}
		}

		float m = pStar / pSum;
		outputReservoir.W = outputReservoir.W > 0.f ? (outputReservoir.weightSum * m) / outputReservoir.W : 0.f;

#elif UNBIASED_RAYTRACED
		int selectedSample = -1;
		TinyUniformSampleGenerator sg1 = sg;
		TinyUniformSampleGenerator sg2 = sg;
		[unroll]
        for (int i = 0; i < SPATIAL_REUSE_SAMPLE_COUNT; i++)
        {
            uint2 neighborPixel = getRandomNeighborPixel(pixel, sg1);

			// Discard pixel if out of bounds
			if(any(neighborPixel >= gFrameDim) || any(neighborPixel < 0)) continue;

			ShadingData sdNeighbor;
			let lod = ExplicitLodTextureSampler(0.f);
			if(!loadShadingData(neighborPixel, gFrameDim, gScene.camera, gVBuffer, lod, sdNeighbor)) return;

            uint neighborBufferIndex = getBufferIndex(neighborPixel, gFrameDim);
            Reservoir neighborReservoir = Reservoir::unpack(gReservoirs[neighborBufferIndex]);

            if (neighborReservoir.W == 0.0f) continue;

			const float3 primaryRayDirNeighbor = getPrimaryRayDir(neighborPixel, gFrameDim, gScene.camera);
			const float distNeighbor = distance(sdNeighbor.posW, primaryRayOrigin);
			let bsdfNeighbor = gScene.materials.getBSDF(sdNeighbor, lod);

			if(!isValidNeighbor(sd.N, sdNeighbor.N, distCurrent, distNeighbor)) continue;

            float neighborReservoirTargetPDF = surfaceData.evalTargetPDF(neighborReservoir.sample, sg);
            if (outputReservoir.update(neighborReservoir, neighborReservoirTargetPDF, sg))
			{
				selectedSample = i;
			}
		}

        float pSum = 0.f;
        float currPixelTargetPDF = surfaceData.evalTargetPDF(outputReservoir.sample, sg);
        currPixelTargetPDF *= surfaceData.evalVisibility(outputReservoir.sample.pointS);
        pSum += currPixelTargetPDF * currentReservoir.M;
		float pStar;
		if(selectedSample == -1)
		{
			pStar = currPixelTargetPDF;
		}

		[unroll]
        for (int i = 0; i < SPATIAL_REUSE_SAMPLE_COUNT; i++)
        {
            uint2 neighborPixel = getRandomNeighborPixel(pixel, sg2);

			// Discard pixel if out of bounds
			if(any(neighborPixel >= gFrameDim) || any(neighborPixel < 0)) continue;

			ShadingData sdNeighbor;
			let lod = ExplicitLodTextureSampler(0.f);
			if(!loadShadingData(neighborPixel, gFrameDim, gScene.camera, gVBuffer, lod, sdNeighbor)) return;

            uint neighborBufferIndex = getBufferIndex(neighborPixel, gFrameDim);
            Reservoir neighborReservoir = Reservoir::unpack(gReservoirs[neighborBufferIndex]);
            if (neighborReservoir.W == 0.0f) continue;

			const float3 primaryRayDirNeighbor = getPrimaryRayDir(neighborPixel, gFrameDim, gScene.camera);
			const float distNeighbor = distance(sdNeighbor.posW, primaryRayOrigin);
			let bsdfNeighbor = gScene.materials.getBSDF(sdNeighbor, lod);

			if(!isValidNeighbor(sd.N, sdNeighbor.N, distCurrent, distNeighbor)) continue;

            SurfaceData neighborSurfaceData = SurfaceData::create(sdNeighbor, bsdfNeighbor);

            float neighborPixelTargetPDF = neighborSurfaceData.evalTargetPDF(outputReservoir.sample, sg);
            neighborPixelTargetPDF *= neighborSurfaceData.evalVisibility(outputReservoir.sample.pointS);
            pSum += neighborPixelTargetPDF * neighborReservoir.M;
			if(selectedSample == i) {
				pStar = neighborPixelTargetPDF;
			}
		}

		float m = pStar > 0 ? pStar / pSum : 0.0f;
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
