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


struct SpatialReuseGIPass
{
	uint2   gFrameDim; ///< Frame dimensions.
	uint    gFrameCount; ///< Frame count since scene was loaded.

	// Resources:
    StructuredBuffer<PackedReservoirGI> gReservoirsGI; ///< Buffer with packed reservoirs.
    StructuredBuffer<PackedSurfaceData> gSurfaceData;
	RWStructuredBuffer<PackedReservoirGI> gOutReservoirsGI; ///< Output buffer with packed reservoirs.

    // Debug:
    RWTexture2D<float4> gDebug;

	void execute(const uint2 pixel)
	{
	    if (any(pixel >= gFrameDim)) return;

		// Get index for the structured buffer access.
		uint bufferIndex = getBufferIndex(pixel, gFrameDim);

		// Create sample generator.
		TinyUniformSampleGenerator sg = TinyUniformSampleGenerator(pixel, gFrameCount);

        // Get reservoir with initial candidate samples from the previous pass.
        ReservoirGI currentReservoir = ReservoirGI::unpack(gReservoirsGI[bufferIndex]);
        // gOutReservoirsGI[bufferIndex] = currentReservoir.pack();
        // return;

		// Create output reservoir.
		ReservoirGI outputReservoir;

        const float3 primaryRayOrigin = gScene.camera.getPosition();
        const float3 primaryRayDir = getPrimaryRayDir(pixel, gFrameDim, gScene.camera);
        const float3 viewVec = -normalize(primaryRayDir);

        // Get pixel Data for the current pixel.
        SurfaceData surfaceData = SurfaceData::unpack(gSurfaceData[bufferIndex]);
        if (!surfaceData.isValid()) return;

        SampleGI currLightSample = currentReservoir.sample;
        float currReservoirTargetPDF = luminance(currLightSample.Le);

        float Z = 0.f;
        outputReservoir.update(currentReservoir, currReservoirTargetPDF, sg);
        Z += outputReservoir.M;

        float3 rayOrigin = computeRayOrigin(surfaceData.position, surfaceData.normal);
		[unroll]
		for(int i = 0; i < 5; i++)
		{
            uint2 neighborPixel = getRandomNeighborPixel(pixel, sg, 0.1f * gFrameDim.x);
            // uint2 neighborPixel = getRandomNeighborPixel(pixel, sg, 300.0f);

			// Discard pixel if out of bounds
			if(any(neighborPixel >= gFrameDim) || any(neighborPixel < 0)) continue;

			uint neighborBufferIndex = getBufferIndex(neighborPixel, gFrameDim);
			ReservoirGI neighborReservoir = ReservoirGI::unpack(gReservoirsGI[neighborBufferIndex]);

            if (neighborReservoir.M == 0.f) continue;

            SurfaceData neighborSurfaceData = SurfaceData::unpack(gSurfaceData[neighborBufferIndex]);
            if (!neighborSurfaceData.isValid()) continue;

            if (!isValidNeighbor(surfaceData.normal, neighborSurfaceData.normal, surfaceData.depth, neighborSurfaceData.depth)) continue;

            SampleGI neighborLightSample = neighborReservoir.sample;
            float neighborReservoirTargetPDF = luminance(neighborLightSample.Le);

            // Calculate Jacobian determinant
            float3 q2q1 = neighborSurfaceData.position - neighborLightSample.samplePoint;
            float3 q2r1 = surfaceData.position - neighborLightSample.samplePoint;
            // Discard back-face samples
            if (dot(surfaceData.normal, -normalize(q2r1)) <= 0.f) continue;

            float cosPhiR = dot(normalize(q2r1), neighborLightSample.sampleNormal);
            float cosPhiQ = dot(normalize(q2q1), neighborLightSample.sampleNormal);

            if (cosPhiR <= 0.f || cosPhiQ <= 0.f) continue;

            float invJ = (cosPhiQ * dot(q2r1, q2r1)) / (cosPhiR * dot(q2q1, q2q1));
            neighborReservoirTargetPDF *= invJ;

            // Test visibility by tracing a shadow ray.
            // Create a DXR 1.1 query object to trace a ray (the <1> means use alpha testing)
            SceneRayQuery<1> rayQuery;
            const Ray ray = Ray(rayOrigin, normalize(-q2r1), 0.0f, length(q2r1) - kShadowRayEpsilon);
            bool visible = rayQuery.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff);
            if (!visible) {
                neighborReservoirTargetPDF = 0.f;
            }
            bool selected = outputReservoir.update(neighborReservoir, neighborReservoirTargetPDF, sg);

            if (visible && selected) {
                Z += neighborReservoir.M;
                // gDebug[pixel] = float4(1, 0, 0, 1);
            }

		}

        // outputReservoir.W = outputReservoir.W > 0.f ? (outputReservoir.weightSum / outputReservoir.M ) / outputReservoir.W : 0.f;
        outputReservoir.W = outputReservoir.W > 0.f ? outputReservoir.weightSum / (outputReservoir.M * outputReservoir.W) : 0.f;
        outputReservoir.M = min(outputReservoir.M, 500);
		// Store reservoir
		gOutReservoirsGI[bufferIndex] = outputReservoir.pack();
	}
}

cbuffer CB
{
    SpatialReuseGIPass gSpatialReuseGIPass;
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId : SV_DispatchThreadID)
{
    gSpatialReuseGIPass.execute(dispatchThreadId.xy);
}
