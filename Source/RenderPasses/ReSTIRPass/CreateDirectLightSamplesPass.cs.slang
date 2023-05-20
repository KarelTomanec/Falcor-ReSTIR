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
    StructuredBuffer<PackedNormalDepth> gNormalDepth;
    RWStructuredBuffer<PackedDirectLightSample> gDirectLightSamples;

    LightSampler gLightSampler; ///< Custom light wrapper for sampling various kinds of lights (EmissiveGeometry, Environment, ...).

    // Debug:
    RWTexture2D<float4> gDebug;

    float4 getColorFromLightIndex(uint index)
    {
        uint aliasTableSize = gLightSampler.emissiveGeometryAliasTable.count;
        index = index % aliasTableSize;
        uint N = 3;
        float index255 = 255.f * float(index) / float(aliasTableSize);
        uint r = float(uint(index255) % N) / float(N - 1);
        uint g = float(uint(index255 / float(N)) % N) / float(N - 1);
        uint b = float(uint(index255 / float(N * N)) % N) / float(N - 1);
        float gamma = 1.f / 2.2f;
        return float4(pow(float(r), gamma), pow(float(g), gamma), pow(float(b), gamma), 1);
    }

	void execute(const uint2 pixel)
    {
	    if (any(pixel >= gFrameDim))
            return;

		// Get index for the structured buffer access.
		uint bufferIndex = getBufferIndex(pixel, gFrameDim);

        // Create pixel Data for the current pixel.
        NormalDepth normalDepth = NormalDepth::unpack(gNormalDepth[bufferIndex]);
        if (!normalDepth.isValid())
            return;
        SurfaceData surfaceData = SurfaceData::unpack(gSurfaceData[bufferIndex]);

        Reservoir reservoir = Reservoir::unpack(gReservoirs[bufferIndex]);

        LightSample lightSample = gLightSampler.getLightSample(reservoir.sample);

        // Visualize light index
        // uint index = reservoir.sample.getIndex();
        // gDebug[pixel] = getColorFromLightIndex(index);

        DirectLightSample outputSample = {};

        float3 rayOrigin = computeRayOrigin(surfaceData.position, surfaceData.normal);

        switch (lightSample.lightType)
        {
            case LightSample::Type::PointLight:
            {

                float3 originToLight = lightSample.posDir - rayOrigin;
                float distSqr = max(FLT_MIN, dot(originToLight, originToLight));
                outputSample.distance = sqrt(distSqr);
                outputSample.direction = originToLight / outputSample.distance;
                float geometryFactor = 1.f / distSqr;
                outputSample.Le = gLightSampler.getLightSampleRadiance(reservoir.sample) * reservoir.W * geometryFactor;
                break;
            }
            case LightSample::Type::AreaLight:
            {
                float3 originToLight = lightSample.posDir - rayOrigin;
                float distSqr = max(FLT_MIN, dot(originToLight, originToLight));
                outputSample.distance = sqrt(distSqr);
                outputSample.direction = originToLight / outputSample.distance;
                float geometryFactor = max(0.f, dot(lightSample.normal, -outputSample.direction)) / distSqr;
                outputSample.Le = gLightSampler.getLightSampleRadiance(reservoir.sample) * reservoir.W * geometryFactor;
                break;
            }
            case LightSample::Type::DistantLight:
            {
                outputSample.direction = lightSample.posDir;
                outputSample.distance = lightSample.getDistanceToSample(surfaceData.position);
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
