
#include "Utils/Math/MathConstants.slangh"

import Rendering.Materials.IBSDF;
import Utils.Sampling.TinyUniformSampleGenerator;
import Scene.RaytracingInline;
import HelperFunctions;
import Utils.Color.ColorHelpers;
import Rendering.Materials.Microfacet;
import Rendering.Materials.Fresnel;
import Utils.Math.PackedFormats;

import LightSampler;

import Reservoir;

struct PackedSurfaceData ///< 32 bytes
{
    uint3 position;
    uint normal;
    uint specularWeight;
    uint diffuseWeight;
    uint specularRoughness;
    uint pad0;
}

struct SurfaceData
{
    float3 position;
    float3 normal;
    float diffuseWeight;
    float specularWeight;
    float specularRoughness;

    static SurfaceData create(const ShadingData sd, const IBSDF bsdf)
    {
        SurfaceData surfaceData = {};
        surfaceData.position = sd.posW;
        surfaceData.normal = sd.N;
        BSDFProperties bsdfProp = bsdf.getProperties(sd);
        surfaceData.diffuseWeight = luminance(bsdfProp.diffuseReflectionAlbedo);
        surfaceData.specularWeight = luminance(bsdfProp.specularReflectionAlbedo);
        surfaceData.specularRoughness = bsdfProp.roughness;

        return surfaceData;
	}

    static SurfaceData unpack(const PackedSurfaceData packedSurfaceData)
    {
        SurfaceData surfaceData;
        surfaceData.position = asfloat(packedSurfaceData.position);
        surfaceData.normal = decodeNormal2x16(packedSurfaceData.normal);
        surfaceData.diffuseWeight = asfloat(packedSurfaceData.diffuseWeight);
        surfaceData.specularWeight = asfloat(packedSurfaceData.specularWeight);
        surfaceData.specularRoughness = asfloat(packedSurfaceData.specularRoughness);

        return surfaceData;
    }

    PackedSurfaceData pack()
    {
        PackedSurfaceData packedSurfaceData = {};
        packedSurfaceData.position = asuint(this.position);
        packedSurfaceData.normal = encodeNormal2x16(this.normal);
        packedSurfaceData.diffuseWeight = asuint(this.diffuseWeight);
        packedSurfaceData.specularWeight = asuint(this.specularWeight);
        packedSurfaceData.specularRoughness = asuint(this.specularRoughness);

        return packedSurfaceData;
    }

    float evalBRDF(float3 wi, float3 wo)
    {
        float wiDotN = saturate(dot(wi, normal));
        float woDotN = saturate(dot(wo, normal));
        float3 H = normalize(wi + wo);
        float NDotH = saturate(dot(normal, H));
        float wiDotH = saturate(dot(wi, H));

        float alpha = specularRoughness * specularRoughness; // GGX width parameter
        float D = evalNdfGGX(alpha, NDotH);
        float G = evalMaskingSmithGGXSeparable(alpha, woDotN, wiDotN);
        float F = specularWeight < 1e-8f ? 0.f : evalFresnelSchlick(specularWeight, 1.f, wiDotH) / specularWeight;

        float diffuse = M_1_PI * wiDotN;
        float specular = max(0.f, D * G * F * 0.25f / woDotN);

        float weightSum = diffuseWeight + specularWeight;
        float diffuseSpecularMix = weightSum < 1e-7f ? 1.f : diffuseWeight / weightSum;

        return wiDotN > 0.f ? lerp(specular, diffuse, diffuseSpecularMix) : 0.f;
    }

    float evalTargetPDF<S : ISampleGenerator>(const LightSample sample, float3 wo, inout S sg)
    {
        switch (sample.lightType)
        {
        case LightSample::Type::AreaLight:
            {
                const float3 pointToLightVec = sample.posDir - position;
                const float distSq = dot(pointToLightVec, pointToLightVec);
                const float3 wi = pointToLightVec / sqrt(distSq);
                const float geometryFactor = max(0.f, dot(-wi, sample.normal)) / distSq;
                const float brdfWeight = evalBRDF(wi, wo);
                return sample.Le * brdfWeight * geometryFactor;
            }
        case LightSample::Type::DistantLight:
            {
                const float3 wi = sample.posDir;
                const float brdfWeight = evalBRDF(wi, wo);
                return sample.Le * brdfWeight;
            }
        }
        return 0.f;
	}

	float evalVisibility(float3 samplePosition)
	{
        SceneRayQuery<1> rayQuery;
        const Ray ray = Ray(position, normalize(samplePosition - position), 0.1f, distance(position, samplePosition) - kShadowRayEpsilon);
		return rayQuery.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff);
	}
};
