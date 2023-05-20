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
    static const uint kNeighborCount = 5;
    static const uint kInitialRadius = 30.f;
    static const uint kRadiusMultipier = 1.2f;

    bool evalSegmentVisibility(float3 pos, float3 endPoint)
    {
        float3 offset = endPoint - pos;
        float tMax = length(offset);
        float3 dir = offset / tMax;
        const Ray ray = Ray(pos, dir, 0.f, tMax);
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
        outputReservoir.update(currentReservoir, currReservoirTargetPDF, sg);

        float3 rayOrigin = computeRayOrigin(surfaceData.position, surfaceData.normal);
        TinyUniformSampleGenerator sg1 = sg;
        TinyUniformSampleGenerator sg2 = sg;

        uint validNeighborFlags = 0;
        float radiusCache[kNeighborCount] = {};
        float radius = kInitialRadius;
        [unroll]
        for (int i = 0; i < kNeighborCount; i++)
        {
            radiusCache[i] = radius;
            // uint2 neighborPixel = getRandomNeighborPixel(pixel, sg1, 0.1f * gFrameDim.x);
            // uint2 neighborPixel = getRandomNeighborPixel(pixel, sg1, 300.0f);
            uint2 neighborPixel = getRandomNeighborPixel(pixel, sg1, radius);

			// Discard pixel if out of bounds
			if(any(neighborPixel >= gFrameDim) || any(neighborPixel < 0))
                continue;

            uint neighborBufferIndex = getBufferIndex(neighborPixel, gFrameDim);
            ReservoirGI neighborReservoir = ReservoirGI::unpack(gReservoirsGI[neighborBufferIndex]);

            SurfaceData neighborSurfaceData = SurfaceData::unpack(gSurfaceData[neighborBufferIndex]);
            if (!neighborSurfaceData.isValid())
                continue;

            if (neighborReservoir.M == 0.f)
                continue;

            if (!isValidNeighbor(surfaceData.normal, neighborSurfaceData.normal, surfaceData.depth, neighborSurfaceData.depth, 0.1f, 0.95f))
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

            if (cosA <= 0.f || cosPhiA <= 0.f || r1q2LenSq <= 0.f || q1q2LenSq <= 0.f) {

                neighborReservoirTargetPDF = 0.f;
            }

            // Evaluate visibility
            bool isVisible = evalSegmentVisibility(rayOrigin, neighborLightSample.samplePoint);
            if (!isVisible)
                neighborReservoirTargetPDF = 0.f;

            // Calculate Jacobian determinant
            float jacobian = r1q2LenSq * cosPhiB <= 0.f ? 0.f : clamp(q1q2LenSq * cosPhiA / (r1q2LenSq * cosPhiB), 0.f, FLT_LARGE);
            neighborReservoirTargetPDF *= jacobian;

            outputReservoir.update(neighborReservoir, neighborReservoirTargetPDF, sg);

            validNeighborFlags |= (1u << i);
            radius = min(radius * kRadiusMultipier, 0.1f * gFrameDim.y);
        }

        float targetPdf = luminance(outputReservoir.sample.Le);
        uint Z = 0;

        if (targetPdf > 0.f) {
            if (evalSegmentVisibility(surfaceData.position, outputReservoir.sample.samplePoint))
                Z += currentReservoir.M;

            [unroll]
            for (int i = 0; i < kNeighborCount; i++)
            {
                if (!(validNeighborFlags & (1u << i)))
                    continue;
                uint2 neighborPixel = getRandomNeighborPixel(pixel, sg2, radiusCache[i]);

                uint neighborBufferIndex = getBufferIndex(neighborPixel, gFrameDim);
                SurfaceData neighborSurfaceData = SurfaceData::unpack(gSurfaceData[neighborBufferIndex]);

                // Evaluate visibility
                if (evalSegmentVisibility(computeRayOrigin(neighborSurfaceData.position, neighborSurfaceData.normal), outputReservoir.sample.samplePoint)) {
                    ReservoirGI neighborReservoir = ReservoirGI::unpack(gReservoirsGI[neighborBufferIndex]);
                    Z += neighborReservoir.M;
                }
            }
        }
        float m = Z > 0 ? 1.f / Z : 0.f;
        outputReservoir.W = outputReservoir.W > 0.f ? (outputReservoir.weightSum * m) / (outputReservoir.W) : 0.f;
        outputReservoir.M = min(outputReservoir.M, 300);
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
