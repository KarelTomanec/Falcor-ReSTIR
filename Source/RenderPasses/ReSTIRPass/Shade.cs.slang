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
import ReservoirGI;
import HelperFunctions;
import LightSampler;

struct ShadePass
{
    uint2   gFrameDim; ///< Frame dimensions.
	uint    gFrameCount; ///< Frame count since scene was loaded.


    // Resources:
    Texture2D<PackedHitInfo> gVBuffer; ///< Fullscreen V-buffer for the primary hits.

    StructuredBuffer<PackedDirectLightSample> gDirectLightSamples;

	RWTexture2D<float4> gOutputColor;
    RWTexture2D<float4> gOutputAlbedo;

    RWTexture2D<float4> gDebug;

	// Static configuration based on defines set from the host.
	#define is_valid(name) (is_valid_##name != 0)
	static const bool kUseEnvBackground = USE_ENV_BACKGROUND;
	static const float3 kDefaultBackgroundColor = float3(0, 0, 0);

    float3 evalDirectLight(const uint2 pixel, ShadingData sd, const IBSDF bsdf, inout TinyUniformSampleGenerator sg)
    {
        uint bufferIndex = getBufferIndex(pixel, gFrameDim);
        DirectLightSample directLightSample = DirectLightSample::unpack(gDirectLightSamples[bufferIndex]);

        float3 rayOrigin = sd.computeNewRayOrigin();
        float3 dirToLight = directLightSample.direction;
        float distToLight = directLightSample.distance;
        dirToLight = dirToLight;
        float3 Li = directLightSample.Le;

        bool valid = true;

        if (valid)
        {
            // Create a DXR 1.1 query object to trace a ray (the <1> means use alpha testing)
            SceneRayQuery<1> rayQuery;
            const Ray ray = Ray(rayOrigin, dirToLight, 0.0f, distToLight - kShadowRayEpsilon);
            if (!rayQuery.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff))
            {
                valid = false;
            }
        }

        float3 diffuse = float3(0.f);
        float3 specular = float3(0.f);

        if (valid)
        {
            sd.mtl.setActiveLobes((uint)LobeType::DiffuseReflection);
            diffuse = bsdf.eval(sd, dirToLight, sg) * Li;

            sd.mtl.setActiveLobes((uint)LobeType::SpecularReflection);
            specular = bsdf.eval(sd, dirToLight, sg) * Li;
        }

        return diffuse + specular;
    }

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

            albedo = clamp(bsdfProperties.diffuseReflectionAlbedo + bsdfProperties.specularReflectionAlbedo, 0.f, 1.f);
            color += bsdfProperties.emission;

            // Create sample generator.
            TinyUniformSampleGenerator sg = TinyUniformSampleGenerator(pixel, gFrameCount);

            float3 directLight = evalDirectLight(pixel, sd, bsdf, sg);
            float3 indirectLight = float3(0.f);

            color += directLight + indirectLight;
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
