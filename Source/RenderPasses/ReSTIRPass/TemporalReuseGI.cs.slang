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
    static const uint kMCap = GI_TEMPORAL_MCAP;
    static const float kMaxOffset = 5.f;
    static const uint kAttemptCount = 1;

	uint2   gFrameDim; ///< Frame dimensions.
	uint    gFrameCount; ///< Frame count since scene was loaded.

    LightSampler gLightSampler;

    // Resources:

	Texture2D<float2> gMotionVectors; ///< 2D screen space motion vector.

    StructuredBuffer<PackedSurfaceData> gSurfaceData;
    StructuredBuffer<PackedSurfaceData> gPrevSurfaceData;
	RWStructuredBuffer<PackedReservoirGI> gPrevGIReservoirs; ///< Buffer with packed reservoirs from the previous frame.
	StructuredBuffer<PackedReservoirGI> gGIReservoirs; ///< Buffer with packed reservoirs.

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
        ReservoirGI currentReservoir = ReservoirGI::unpack(gGIReservoirs[bufferIndex]);
        // gPrevGIReservoirs[bufferIndex] = currentReservoir.pack();
        // return;

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
            if (!isValidNeighbor(surfaceData.normal, prevSurfaceData.normal, surfaceData.depth, prevSurfaceData.depth, kDepthThreshold, kNormalThreshold))
                continue;

            neighborFound = true;
            break;
		}

        if (!neighborFound) {
            gPrevGIReservoirs[bufferIndex] = currentReservoir.pack();
        }

        // Get index for the structured buffer access for the previous pixel.
        uint prevBufferIndex = getBufferIndex(prevPixel, gFrameDim);

        ReservoirGI outputReservoir;
        // Get final reservoir from the previous frame.
        ReservoirGI prevReservoir = ReservoirGI::unpack(gPrevGIReservoirs[prevBufferIndex]);

        // Clamp the previous frame's M.
        prevReservoir.M = min(prevReservoir.M, kMCap);

        // Standard combination of multiple reservoirs reservoirs (Algorithm 4 from the original paper):
        float prevTargetPdf = luminance(prevReservoir.sample.Le);
        outputReservoir.update(prevReservoir, prevTargetPdf, sg);

        float targetPdf = luminance(currentReservoir.sample.Le);
        outputReservoir.update(currentReservoir, targetPdf, sg);

        outputReservoir.W = outputReservoir.W  > 0.f ? outputReservoir.weightSum / (outputReservoir.M * outputReservoir.W) : 0.f;
        // Store combined reservoir.
        gPrevGIReservoirs[bufferIndex] = outputReservoir.pack();

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
