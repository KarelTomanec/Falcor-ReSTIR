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

import Reservoir;
import HelperFunctions;
import LightSampler;

struct ShadePass
{
    uint2   gFrameDim; ///< Frame dimensions.
	uint    gFrameCount; ///< Frame count since scene was loaded.

    LightSampler gLightSampler;

	// Resources:
	Texture2D<PackedHitInfo> gVBuffer; ///< Fullscreen V-buffer for the primary hits.
    StructuredBuffer<PackedReservoir> gReservoirs; ///< Buffer with packed reservoirs.
	RWTexture2D<float4> gOutputColor;
    RWTexture2D<float4> gOutputAlbedo;

    RWTexture2D<float4> gDebug;
    RWTexture2D<float4> gDebugSameSamples;

	// Static configuration based on defines set from the host.
	#define is_valid(name) (is_valid_##name != 0)
	static const bool kUseEnvBackground = USE_ENV_BACKGROUND;
	static const float3 kDefaultBackgroundColor = float3(0, 0, 0);

	void execute(const uint2 pixel)
	{
		float3 color = float3(0.f);
		float3 albedo = float3(0.f);

		if (any(pixel >= gFrameDim)) return;

		const float3 primaryRayOrigin = gScene.camera.getPosition();
		const float3 primaryRayDir = getPrimaryRayDir(pixel, gFrameDim, gScene.camera);

		ShadingData sd;
		let lod = ExplicitLodTextureSampler(0.f);
		if(loadShadingData(pixel, gFrameDim, gScene.camera, gVBuffer, lod, sd))
		{
			// Create BSDF instance at shading point.
			let bsdf = gScene.materials.getBSDF(sd, lod);
			let bsdfProperties = bsdf.getProperties(sd);

			albedo = bsdfProperties.diffuseReflectionAlbedo + bsdfProperties.specularReflectionAlbedo;

            uint bufferIndex = getBufferIndex(pixel, gFrameDim);
            Reservoir reservoir = Reservoir::unpack(gReservoirs[bufferIndex]);
            LightSample lightSample = gLightSampler.getLightSample(reservoir.sample);

            float3 rayOrigin = sd.computeNewRayOrigin();
            float3 dirToLight;
            float distToLight;
            float3 Li;
            switch (lightSample.lightType)
            {
            case LightSample::Type::AreaLight:
                {
                    float3 originToLight = lightSample.posDir - rayOrigin;
                    dirToLight = normalize(originToLight);
                    float distSqr = max(FLT_MIN, dot(originToLight, originToLight));
                    float geometryFactor = max(0.f, dot(lightSample.normal, -dirToLight)) / distSqr;
                    distToLight = sqrt(distSqr);
                    Li = gLightSampler.getLightSampleRadiance(reservoir.sample) * reservoir.W * geometryFactor;
                    break;
                }
                case LightSample::Type::DistantLight:
                {
                    dirToLight = lightSample.posDir;
                    distToLight = lightSample.getDistanceToSample(rayOrigin);
                    Li = gLightSampler.getLightSampleRadiance(reservoir.sample) * reservoir.W;
                    break;
                }
            }

			bool valid = true;

			if(reservoir.W == 0.0f)
			{
				valid = false;
			}

			if(valid)
			{
				// Create a DXR 1.1 query object to trace a ray (the <1> means use alpha testing)
                SceneRayQuery<1> rayQuery;
                const Ray ray = Ray(rayOrigin, dirToLight, 0.0f, distToLight - kShadowRayEpsilon);
				if (!rayQuery.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff))
				{
					valid = false;
				}
			}

			float3 diffuse = {};
			float3 specular = {};
			float3 emission = {};

			if(valid)
			{
				// Create sample generator.
				TinyUniformSampleGenerator sg = TinyUniformSampleGenerator(pixel, gFrameCount);

				sd.mtl.setActiveLobes((uint)LobeType::DiffuseReflection);
                diffuse = bsdf.eval(sd, dirToLight, sg) * Li;

                sd.mtl.setActiveLobes((uint)LobeType::SpecularReflection);
                specular = bsdf.eval(sd, dirToLight, sg) * Li;
			}

			emission = bsdfProperties.emission;

            color = emission + diffuse + specular;
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
	ShadePass gShadePass;
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId : SV_DispatchThreadID)
{
	gShadePass.execute(dispatchThreadId.xy);
}
