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

struct DecoupledPipelinePass
{

    static const uint kLightTileCount = LIGHT_TILE_COUNT;
    static const uint kLightTileSize = LIGHT_TILE_SIZE;
    static const uint kScreenTileSize = LIGHT_TILE_SCREEN_SIZE;

    static const uint kLightTileEmissiveSampleCount = LIGHT_TILE_EMISSIVE_SAMPLE_COUNT;
    static const uint kLightTileEnvironmentSampleCount = LIGHT_TILE_ENVIRONMENT_SAMPLE_COUNT;
    static const uint kLightTileAnalyticSampleCount = LIGHT_TILE_ANALYTIC_SAMPLE_COUNT;

	static const bool kUseAnalyticLights = USE_ANALYTIC_LIGHTS;
	static const bool kUseEmissiveLights = USE_EMISSIVE_LIGHTS;
	static const bool kUseEnvLight = USE_ENV_LIGHT;
	static const bool kUseEnvBackground = USE_ENV_BACKGROUND;
	static const float3 kDefaultBackgroundColor = float3(0, 0, 0);

    static const uint kEmissiveLightCandidateCount = EMISSIVE_LIGHT_CANDIDATE_COUNT;
    static const uint kEnvironmentLightCandidateCount = ENV_LIGHT_CANDIDATE_COUNT;
    static const uint kAnalyticLightCandidateCount = ANALYTIC_LIGHT_CANDIDATE_COUNT;

    static const float kMaxOffset = 5.f;
    static const uint kAttemptCount = 1;

    static const float kSpatialVisibilityThreshold = SPATIAL_VISIBILITY_THRESHOLD;


    uint2 gFrameDim;  ///< Frame dimensions.
    uint gFrameCount; ///< Frame count since scene was loaded.

    LightSampler gLightSampler; ///< Custom light wrapper for sampling various kinds of lights (EmissiveGeometry, Environment, ...).

    // Resources:
    Texture2D<PackedHitInfo> gVBuffer;
    StructuredBuffer<PackedLightSample> gLightTiles;

    RWStructuredBuffer<PackedReservoir> gReservoirs;
    RWStructuredBuffer<PackedSurfaceData> gSurfaceData;

    StructuredBuffer<PackedReservoir> gPrevReservoirs;
    StructuredBuffer<PackedSurfaceData> gPrevSurfaceData;

    RWTexture2D<float4> gOutputColor;
    RWTexture2D<float4> gOutputAlbedo;

    Texture2D<float2> gMotionVectors; ///< 2D screen space motion vector.

    // Debug:
	RWTexture2D<float4> gDebug;

	void execute(const uint2 pixel)
    {
        if (any(pixel >= gFrameDim))
            return;

        float3 color = float3(0.f);
        float3 albedo = float3(0.f);

        ShadingData sd;
        let lod = ExplicitLodTextureSampler(0.f);

        const float3 primaryRayOrigin = gScene.camera.getPosition();
        const float3 primaryRayDir = getPrimaryRayDir(pixel, gFrameDim, gScene.camera);

        // Check if pixel represents a valid primary hit.
        if (loadShadingData(pixel, gFrameDim, gScene.camera, gVBuffer, lod, sd))
        {
            // INITIAL RIS -------------------------------------------------------------------------------------------
            Reservoir currentReservoir;

            uint bufferIndex = getBufferIndex(pixel, gFrameDim);

            const float3 viewVec = -normalize(primaryRayDir);

			// Create BSDF instance at shading point.
			let bsdf = gScene.materials.getBSDF(sd, lod);

            // Create surface data from the shading data and bsdf.
            SurfaceData surfaceData = SurfaceData::create(sd, bsdf, primaryRayOrigin);
            gSurfaceData[bufferIndex] = surfaceData.pack();

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
                currentReservoir.update(emissiveLightReservoir, emissiveLocalTargetPDF, sg);
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
                currentReservoir.update(environmentLightReservoir, environmentLocalTargetPDF, sg);
            }

            // Sample analytic lights:
            if (kAnalyticLightCandidateCount > 0)
            {
                uint lightTileOffset = tileIndex * kLightTileSize + kLightTileEmissiveSampleCount + kLightTileEnvironmentSampleCount;
                uint step = (kLightTileAnalyticSampleCount + kAnalyticLightCandidateCount - 1) / kAnalyticLightCandidateCount;
                uint inTileOffset = min(uint(sampleNext1D(sg) * step), step - 1);
                Reservoir analyticLightReservoir;
                [unroll]
                for (uint i = 0; i < kAnalyticLightCandidateCount; i++)
                {
                    uint lightSampleIndex = lightTileOffset + (inTileOffset + i * step) % kLightTileAnalyticSampleCount;
                    const LightSample lightSample = LightSample::unpack(gLightTiles[lightSampleIndex]);

                    const float3 direction = lightSample.getDirToSample(rayOrigin);
                    if (dot(surfaceData.normal, direction) < kMinCosTheta) {
                        analyticLightReservoir.M += 1;
                        continue;
                    }

                    float sourcePDF = lightSample.pdf;
                    float targetPDF = surfaceData.evalTargetPDF(lightSample, viewVec);

                    analyticLightReservoir.update(lightSample.minLightSample, targetPDF, sourcePDF, sg);
                }

                float analyticLocalTargetPDF = analyticLightReservoir.W;
                analyticLightReservoir.W = analyticLightReservoir.W > 0.f ? (analyticLightReservoir.weightSum / analyticLightReservoir.M) / analyticLightReservoir.W : 0.f;
                currentReservoir.update(analyticLightReservoir, analyticLocalTargetPDF, sg);
            }

            {
                // Test visibility by tracing a shadow ray.
                // Create a DXR 1.1 query object to trace a ray (the <1> means use alpha testing)
                SceneRayQuery<1> rayQuery;
                const LightSample lightSample = gLightSampler.getLightSample(currentReservoir.sample);
                const Ray ray = Ray(rayOrigin, lightSample.getDirToSample(rayOrigin), 0.0f, lightSample.getDistanceToSample(rayOrigin) - kShadowRayEpsilon);
                bool visible = rayQuery.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff);
                if (visible) {
                    currentReservoir.W = currentReservoir.W > 0.f ? (currentReservoir.weightSum / currentReservoir.M) / currentReservoir.W : 0.f;
                } else {
                    currentReservoir.W = 0.0f;
                }
            }

            // TEMPORAL SAMPLE -------------------------------------------------------------------------------------------


            // Set history limit for the temporal reuse.
            uint historyLimit = TEMPORAL_MAX_HISTORY_LENGTH * currentReservoir.M;
            // Reproject the pixel position.
            uint2 reprojPos = uint2(float2(pixel) + gMotionVectors[pixel] * gFrameDim + sampleNext2D(sg));

            // ShadingData sdPrev;
            SurfaceData prevSurfaceData;
            uint2 prevPixel = reprojPos;
            bool temporalNeighborFound = false;

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

                temporalNeighborFound = true;
                break;
            }

            // Get index for the structured buffer access for the previous pixel.
            uint prevBufferIndex = getBufferIndex(prevPixel, gFrameDim);

            // Get final reservoir from the previous frame.
            Reservoir prevReservoir = Reservoir::unpack(gPrevReservoirs[prevBufferIndex]);

            // Clamp the previous frame's M.
            prevReservoir.M = min(historyLimit, prevReservoir.M);

            // SPATIAL SAMPLE -------------------------------------------------------------------------------------------
            Reservoir spatioTemporalReservoir;
            bool spatioTemporalNeighborFound = false;
            float spatialNeighborDistance = 0.f;

            [unroll]
            for (uint i = 0; i < SPATIAL_REUSE_SAMPLE_COUNT; i++)
            {
                uint2 neighborPixel = getRandomNeighborPixel(pixel, sg);

                // Discard pixel if out of bounds
                if (any(neighborPixel >= gFrameDim) || any(neighborPixel < 0))
                    continue;

                uint neighborBufferIndex = getBufferIndex(neighborPixel, gFrameDim);
                Reservoir spatialReservoir = Reservoir::unpack(gPrevReservoirs[neighborBufferIndex]);

                if (spatialReservoir.M == 0.f)
                    continue;

                SurfaceData neighborSurfaceData = SurfaceData::unpack(gPrevSurfaceData[neighborBufferIndex]);
                if (!neighborSurfaceData.isValid())
                    continue;

                if (!isValidNeighbor(surfaceData.normal, neighborSurfaceData.normal, surfaceData.depth, neighborSurfaceData.depth))
                    continue;
                spatialReservoir.M = min(historyLimit, spatialReservoir.M);

                LightSample neighborLightSample = gLightSampler.getLightSample(spatialReservoir.sample);
                float neighborReservoirTargetPDF = surfaceData.evalTargetPDF(neighborLightSample, viewVec);
                if (spatioTemporalReservoir.update(spatialReservoir, neighborReservoirTargetPDF, sg)) spatialNeighborDistance = distance(pixel, neighborPixel);
                spatioTemporalNeighborFound = true;
            }

            spatioTemporalReservoir.W = spatioTemporalReservoir.W > 0.f ? (spatioTemporalReservoir.weightSum / spatioTemporalReservoir.M) / spatioTemporalReservoir.W : 0.f;
            spatioTemporalReservoir.M = min(historyLimit, spatioTemporalReservoir.M);

            if (spatioTemporalNeighborFound && spatialNeighborDistance > kSpatialVisibilityThreshold) {
                // Test visibility by tracing a shadow ray.
                // Create a DXR 1.1 query object to trace a ray (the <1> means use alpha testing)
                SceneRayQuery<1> rayQuery;
                const LightSample lightSample = gLightSampler.getLightSample(spatioTemporalReservoir.sample);
                const Ray ray = Ray(rayOrigin, lightSample.getDirToSample(rayOrigin), 0.0f, lightSample.getDistanceToSample(rayOrigin) - kShadowRayEpsilon);
                bool visible = rayQuery.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff);
                if (!visible) {
                    spatioTemporalReservoir.W = 0.0f;
                }
            }


            // COMBINE RESERVOIRS
            Reservoir outputReservoir;
            {
                if (temporalNeighborFound) {
                    LightSample neighborLightSample = gLightSampler.getLightSample(prevReservoir.sample);
                    float neighborReservoirTargetPDF = surfaceData.evalTargetPDF(neighborLightSample, viewVec);
                    outputReservoir.update(prevReservoir, neighborReservoirTargetPDF, sg);
                }

                if (spatioTemporalNeighborFound) {
                    LightSample neighborLightSample = gLightSampler.getLightSample(spatioTemporalReservoir.sample);
                    float neighborReservoirTargetPDF = surfaceData.evalTargetPDF(neighborLightSample, viewVec);
                    outputReservoir.update(spatioTemporalReservoir, neighborReservoirTargetPDF, sg);
                }

                LightSample currentLightSample = gLightSampler.getLightSample(currentReservoir.sample);
                float currentReservoirTargetPDF = surfaceData.evalTargetPDF(currentLightSample, viewVec);
                outputReservoir.update(currentReservoir, currentReservoirTargetPDF, sg);

                outputReservoir.W = outputReservoir.W > 0.f ? (outputReservoir.weightSum / outputReservoir.M) / outputReservoir.W : 0.f;
            }
            gReservoirs[bufferIndex] = outputReservoir.pack();

            // SHADING -------------------------------------------------------------------------------------------

            uint N = 3;
            let bsdfProperties = bsdf.getProperties(sd);
            float3 emission = bsdfProperties.emission;
            albedo = bsdfProperties.diffuseReflectionAlbedo + bsdfProperties.specularReflectionAlbedo;

            Reservoir reservoirs[] = { outputReservoir,  prevReservoir, spatioTemporalReservoir };

            for (uint i = 0; i < N; i++) {
                Reservoir reservoir = reservoirs[i];
                LightSample lightSample = gLightSampler.getLightSample(reservoir.sample);
                float3 dirToLight;
                float3 Li;
                switch (lightSample.lightType)
                {
                    case LightSample::Type::PointLight:
                    case LightSample::Type::AreaLight:
                    {
                        float3 originToLight = lightSample.posDir - rayOrigin;
                        dirToLight = normalize(originToLight);
                        float distSqr = max(FLT_MIN, dot(originToLight, originToLight));
                        float geometryFactor = max(0.f, dot(lightSample.normal, -dirToLight)) / distSqr;
                        Li = gLightSampler.getLightSampleRadiance(reservoir.sample) * reservoir.W * geometryFactor;
                        break;
                    }
                    case LightSample::Type::DistantLight:
                    {
                        dirToLight = lightSample.posDir;
                        Li = gLightSampler.getLightSampleRadiance(reservoir.sample) * reservoir.W;
                        break;
                    }
                }

                bool valid = true;

                if (reservoir.W == 0.0f)
                    valid = false;

                float3 diffuse = {};
                float3 specular = {};

                if (valid)
                {
                    // Create sample generator.
                    TinyUniformSampleGenerator sg = TinyUniformSampleGenerator(pixel, gFrameCount);

                    sd.mtl.setActiveLobes((uint)LobeType::DiffuseReflection);
                    diffuse = bsdf.eval(sd, dirToLight, sg) * Li;

                    sd.mtl.setActiveLobes((uint)LobeType::SpecularReflection);
                    specular = bsdf.eval(sd, dirToLight, sg) * Li;
                }

                color += diffuse + specular;
            }
            color /= float(N);
            color += emission;
        } else {
            // Background pixel.
            color = kUseEnvBackground ? gScene.envMap.eval(primaryRayDir) : kDefaultBackgroundColor;
        }
        gOutputColor[pixel] = float4(color, 1);
        gOutputAlbedo[pixel] = float4(albedo, 1);
	}
}

cbuffer CB
{
    DecoupledPipelinePass gDecoupledPipelinePass;
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId : SV_DispatchThreadID)
{

    gDecoupledPipelinePass.execute(dispatchThreadId.xy);
}
