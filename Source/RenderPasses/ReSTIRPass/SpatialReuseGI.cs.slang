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

    static const float FLT_LARGE = 1e20f;
    static const uint kNeighborCount = 1;

    bool evalSegmentVisibility(float3 pos, float3 endPoint)
    {
        float3 offset = endPoint - pos;
        float tMax = length(offset);
        float3 dir = offset / tMax;
        const Ray ray = Ray(pos, dir, 0.001f, 0.999 * tMax);
        SceneRayQuery<1> sceneRayQuery;
        return sceneRayQuery.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff);
    }

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
        if (!surfaceData.isValid())
            return;

        SampleGI currLightSample = currentReservoir.sample;
        float currReservoirTargetPDF = luminance(currLightSample.Le);

        bool tmpSelected = outputReservoir.update(currentReservoir, currReservoirTargetPDF, sg);

        float Z = 0.f;
        if (tmpSelected && currReservoirTargetPDF > 0.f)
            Z += currentReservoir.M;

        float3 rayOrigin = computeRayOrigin(surfaceData.position, surfaceData.normal);
        [unroll]
        for (int i = 0; i < kNeighborCount; i++)
		{
            // uint2 neighborPixel = getRandomNeighborPixel(pixel, sg, 0.1f * gFrameDim.x);
            uint2 neighborPixel = getRandomNeighborPixel(pixel, sg, 300.0f);
            // uint2 neighborPixel = getRandomNeighborPixel(pixel, sg, 30.0f);

			// Discard pixel if out of bounds
			if(any(neighborPixel >= gFrameDim) || any(neighborPixel < 0))
                continue;

			uint neighborBufferIndex = getBufferIndex(neighborPixel, gFrameDim);
			ReservoirGI neighborReservoir = ReservoirGI::unpack(gReservoirsGI[neighborBufferIndex]);

            if (neighborReservoir.M == 0.f)
                continue;

            SurfaceData neighborSurfaceData = SurfaceData::unpack(gSurfaceData[neighborBufferIndex]);
            if (!neighborSurfaceData.isValid())
                continue;

            if (!isValidNeighbor(surfaceData.normal, neighborSurfaceData.normal, surfaceData.depth, neighborSurfaceData.depth, 0.9f, 0.05f))
                continue;

            SampleGI neighborLightSample = neighborReservoir.sample;
            float neighborReservoirTargetPDF = luminance(neighborLightSample.Le);

            float3 r1q2 = neighborLightSample.samplePoint - surfaceData.position;
            float3 q1q2 = neighborLightSample.samplePoint - neighborLightSample.surfacePoint;

            // Discard back-face samples
            if (dot(surfaceData.normal, r1q2) <= 0.f)
                neighborReservoirTargetPDF = 0.f;

            float r1q2LenSq = dot(r1q2, r1q2);
            float q1q2LenSq = dot(q1q2, q1q2);

            r1q2 = normalize(r1q2);
            q1q2 = normalize(q1q2);

            float cosA = dot(surfaceData.normal, r1q2);
            float cosB = dot(neighborLightSample.surfaceNormal, q1q2);
            float cosPhiA = -dot(r1q2, neighborLightSample.sampleNormal);
            float cosPhiB = -dot(q1q2, neighborLightSample.sampleNormal);
            if (cosB <= 0.f || cosPhiB <= 0.f)
                continue;

            if (cosA <= 0.f || cosPhiA <= 0.f || r1q2LenSq <= 0.f || q1q2LenSq <= 0.f)
                neighborReservoirTargetPDF = 0.f;

            // Evaluate visibility
            bool isVisible = evalSegmentVisibility(rayOrigin, neighborLightSample.samplePoint);
            if (!isVisible)
                neighborReservoirTargetPDF = 0.f;

            // Calculate Jacobian determinant
            float jacobian = r1q2LenSq * cosPhiB <= 0.f ? 0.f : clamp(q1q2LenSq * cosPhiA / (r1q2LenSq * cosPhiB), 0.f, FLT_LARGE);
            neighborReservoirTargetPDF *= jacobian;
            // float jacobian = (abs(cosPhiA) / abs(cosPhiB)) * (q1q2LenSq / r1q2LenSq);
            // neighborReservoirTargetPDF /= jacobian;
            // gDebug[pixel] = float4(neighborLightSample., 1);


            bool isSelected = outputReservoir.update(neighborReservoir, neighborReservoirTargetPDF, sg);
            if (isSelected && neighborReservoirTargetPDF > 0.f)
                Z += neighborReservoir.M;
        }
        outputReservoir.W = outputReservoir.M * outputReservoir.W > 0.f ? outputReservoir.weightSum / (outputReservoir.M * outputReservoir.W) : 0.f;
        // outputReservoir.W = outputReservoir.W * Z > 0.f ? outputReservoir.weightSum / (Z * outputReservoir.W) : 0.f;
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
