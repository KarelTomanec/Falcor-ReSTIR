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

import Rendering.Lights.LightHelpers;
import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import Rendering.Lights.EmissivePowerSampler;
import Rendering.Lights.EnvMapSampler;

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

struct GenerateInitialCandidatesPass
{

    static const uint kLightTileCount = LIGHT_TILE_COUNT;
    static const uint kLightTileSize = LIGHT_TILE_SIZE;
    static const uint kScreenTileSize = LIGHT_TILE_SCREEN_SIZE;

    static const uint kLightTileEmissiveSampleCount = LIGHT_TILE_EMISSIVE_SAMPLE_COUNT;
    static const uint kLightTileEnvironmentSampleCount = LIGHT_TILE_ENVIRONMENT_SAMPLE_COUNT;

	static const bool kUseAnalyticLights = USE_ANALYTIC_LIGHTS;
	static const bool kUseEmissiveLights = USE_EMISSIVE_LIGHTS;
	static const bool kUseEnvLight = USE_ENV_LIGHT;
	static const bool kUseEnvBackground = USE_ENV_BACKGROUND;
	static const float3 kDefaultBackgroundColor = float3(0, 0, 0);


	static const uint kEmissiveLightCandidateCount = EMISSIVE_LIGHT_CANDIDATE_COUNT;
	static const uint kEnvironmentLightCandidateCount = ENV_LIGHT_CANDIDATE_COUNT;

    uint2 gFrameDim;  ///< Frame dimensions.
    uint gFrameCount; ///< Frame count since scene was loaded.

	EmissiveLightSampler gEmissiveLightSampler;
    EnvMapSampler gEnvMapSampler;                    ///< Environment map sampler. Only valid when kUseEnvLight == true.

    LightSampler gLightSampler; ///< Custom light wrapper for sampling various kinds of lights (EmissiveGeometry, Environment, ...).

    // Resources:
    Texture2D<PackedHitInfo> gVBuffer;
    StructuredBuffer<PackedLightSample> gLightTiles;
    RWStructuredBuffer<PackedReservoir> gReservoirs;
    RWStructuredBuffer<PackedSurfaceData> gSurfaceData;

    // Debug:
    RWTexture2D<float4> gDebugSameSamples;
	RWTexture2D<float4> gDebug;

	void execute(const uint2 pixel)
    {
	    if (any(pixel >= gFrameDim)) return;

        Reservoir outputReservoir;

        ShadingData sd;
        let lod = ExplicitLodTextureSampler(0.f);

        // Check if pixel represents a valid primary hit.
		if(loadShadingData(pixel, gFrameDim, gScene.camera, gVBuffer, lod, sd))
		{

			const float3 primaryRayOrigin = gScene.camera.getPosition();
			const float3 primaryRayDir = getPrimaryRayDir(pixel, gFrameDim, gScene.camera);

            const float3 viewVec = -normalize(primaryRayDir);

			// Create BSDF instance at shading point.
			let bsdf = gScene.materials.getBSDF(sd, lod);

            // Create surface data from the shading data and bsdf.
            SurfaceData surfaceData = SurfaceData::create(sd, bsdf, primaryRayOrigin);
            gSurfaceData[getBufferIndex(pixel, gFrameDim)] = surfaceData.pack();

			// Compute ray origin for new rays spawned from the G-buffer.
			float3 rayOrigin =  sd.computeNewRayOrigin();

            // Determine screen tile position.
            uint2 screenTilePosition = pixel / kScreenTileSize;

            // Create a sample generator based on the position of the tile, so it's the same for all the pixels in the same tile.
            TinyUniformSampleGenerator tileSg = TinyUniformSampleGenerator(screenTilePosition, gFrameCount);

            // Get random tile index for the screen tile. NOTE: sampleNext1D() -> [0, 1)
            uint tileIndex = uint(sampleNext1D(tileSg) * kLightTileCount);

            // Create a sample generator that is unique for each pixel.
            TinyUniformSampleGenerator sg = TinyUniformSampleGenerator(pixel, gFrameCount);

            // Sample emissive geometry:
            if (kEmissiveLightCandidateCount > 0)
            {
                uint lightTileOffset = tileIndex * kLightTileSize;
                uint step = (kLightTileEmissiveSampleCount + kEmissiveLightCandidateCount - 1) / kEmissiveLightCandidateCount;
                uint inTileOffset = min(uint(sampleNext1D(sg) * step), step - 1);
                Reservoir emissiveLightReservoir;
                [unroll]
                for(uint i = 0; i < kEmissiveLightCandidateCount; i++)
                {
                    uint lightSampleIndex = lightTileOffset + (inTileOffset + i * step) % kLightTileEmissiveSampleCount;
                    LightSample lightSample = LightSample::unpack(gLightTiles[lightSampleIndex]);

                    const float3 direction = normalize(lightSample.posDir - rayOrigin);
                    if (dot(surfaceData.normal, direction) < kMinCosTheta) {
                        emissiveLightReservoir.M += 1;
                        continue;
                    }

                    float sourcePDF = lightSample.pdf;
                    float targetPDF = surfaceData.evalTargetPDF(lightSample, viewVec);

                    emissiveLightReservoir.update(lightSample.minLightSample, targetPDF, sourcePDF, sg);
                }
                float emissiveLocalTargetPDF = emissiveLightReservoir.W;
                emissiveLightReservoir.W = emissiveLightReservoir.W > 0.f ? (emissiveLightReservoir.weightSum / emissiveLightReservoir.M) / emissiveLightReservoir.W : 0.f;
                outputReservoir.update(emissiveLightReservoir, emissiveLocalTargetPDF, sg);
            }

            // Sample environment map:
            if (kEnvironmentLightCandidateCount > 0)
            {
                uint lightTileOffset = tileIndex * kLightTileSize + kLightTileEmissiveSampleCount;
                uint step = (kLightTileEnvironmentSampleCount + kEnvironmentLightCandidateCount - 1) / kEnvironmentLightCandidateCount;
                uint inTileOffset = min(uint(sampleNext1D(sg) * step), step - 1);
                Reservoir environmentLightReservoir;
                [unroll]
                for (uint i = 0; i < kEnvironmentLightCandidateCount; i++)
                {
                    uint lightSampleIndex = lightTileOffset + (inTileOffset + i * step) % kLightTileEnvironmentSampleCount;
                    const LightSample lightSample = LightSample::unpack(gLightTiles[lightSampleIndex]);

                    const float3 direction = lightSample.posDir;
                    if (dot(surfaceData.normal, direction) < kMinCosTheta) {
                        environmentLightReservoir.M += 1;
                        continue;
                    }

                    float sourcePDF = lightSample.pdf;
                    float targetPDF = surfaceData.evalTargetPDF(lightSample, viewVec);

                    environmentLightReservoir.update(lightSample.minLightSample, targetPDF, sourcePDF, sg);
                }
                float environmentLocalTargetPDF = environmentLightReservoir.W;
                environmentLightReservoir.W = environmentLightReservoir.W > 0.f ? (environmentLightReservoir.weightSum / environmentLightReservoir.M) / environmentLightReservoir.W : 0.f;
                outputReservoir.update(environmentLightReservoir, environmentLocalTargetPDF, sg);
            }


#if TEST_INITIAL_SAMPLE_VISIBILITY
            // Test visibility by tracing a shadow ray.
            // Create a DXR 1.1 query object to trace a ray (the <1> means use alpha testing)
            SceneRayQuery<1> rayQuery;
            const LightSample lightSample = gLightSampler.getLightSample(outputReservoir.sample);
            const Ray ray = Ray(rayOrigin, lightSample.getDirToSample(rayOrigin), 0.0f, lightSample.getDistanceToSample(rayOrigin) - kShadowRayEpsilon);
            bool visible = rayQuery.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff);
            if (visible) {
                outputReservoir.W = outputReservoir.W > 0.f ? (outputReservoir.weightSum / outputReservoir.M) / outputReservoir.W : 0.f;
            } else {
                outputReservoir.W = 0.0f;
			}
#else
            outputReservoir.W = outputReservoir.W > 0.f ? (outputReservoir.weightSum / outputReservoir.M) / outputReservoir.W : 0.f;
#endif
            // outputReservoir.M = 1;
        } else {
            // Create invalid surface data.
            SurfaceData invalidSurfaceData = SurfaceData::createInvalid();
            gSurfaceData[getBufferIndex(pixel, gFrameDim)] = invalidSurfaceData.pack();
        }
        gReservoirs[getBufferIndex(pixel, gFrameDim)] = outputReservoir.pack();
        gDebugSameSamples[pixel] = float4(asfloat(outputReservoir.sample.typeIndex), 0, 0, 1);
	}
}

cbuffer CB
{
    GenerateInitialCandidatesPass gGenerateInitialCandidatesPass;
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId : SV_DispatchThreadID)
{

    gGenerateInitialCandidatesPass.execute(dispatchThreadId.xy);
}
