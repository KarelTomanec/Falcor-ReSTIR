
#include "Utils/Math/MathConstants.slangh"

import Rendering.Materials.IBSDF;
import Utils.Sampling.TinyUniformSampleGenerator;
import Scene.RaytracingInline;
import HelperFunctions;
import Utils.Color.ColorHelpers;
import Rendering.Materials.Microfacet;
import Rendering.Materials.Fresnel;
import Utils.Math.PackedFormats;
import Utils.Geometry.GeometryHelpers;

import LightSampler;

import Reservoir;

/** A structure that represents the packed form of normal and depth information of a point in a scene using just 8 bytes.
 */
struct PackedNormalDepth
{
    uint normal; ///< Packed normal vector at the point in the scene.
    uint depth;  ///< Packed depth (distance from a camera) at the point in the scene.
};

/** A structure that represents the normal and depth information of a point in a scene.
 */
struct NormalDepth
{
    float3 normal; ///< The normal vector at the point in the scene.
    float depth;   ///< The depth (distance from a camera) at the point in the scene.

    /** Creates an invalid instance of NormalDepth with depth set to negative infinity. This is typically used to indicate absence of a valid normal and depth.
     */
    static NormalDepth createInvalid()
    {
        NormalDepth normalDepth = {};
        normalDepth.depth = -FLT_MAX;
        return normalDepth;
    }

    /** Creates an instance of NormalDepth with given normal vector and depth.
     * \param[in] normal The normal vector at the point in the scene.
     * \param[in] depth The depth (distance from a camera) at the point in the scene.
     */
    static NormalDepth create(const float3 normal, const float depth)
    {
        NormalDepth normalDepth = {};
        normalDepth.normal = normal;
        normalDepth.depth = depth;
        return normalDepth;
    }

    /** Unpacks a `PackedNormalDepth` into a `NormalDepth` instance.
     * \param[in] packedNormalDepth The packed normal and depth information to be unpacked.
     */
    static NormalDepth unpack(const PackedNormalDepth packedNormalDepth)
    {
        NormalDepth normalDepth = {};
        normalDepth.normal = decodeNormal2x16(packedNormalDepth.normal);
        normalDepth.depth = asfloat(packedNormalDepth.depth);
        return normalDepth;
    }

    /** Packs the `NormalDepth` instance into a `PackedNormalDepth`.
     */
    PackedNormalDepth pack()
    {
        PackedNormalDepth packedNormalDepth = {};
        packedNormalDepth.normal = encodeNormal2x16(this.normal);
        packedNormalDepth.depth = asuint(this.depth);
        return packedNormalDepth;
    }

    /** Checks if the `NormalDepth` instance is valid. A `NormalDepth` is considered valid if its depth is not negative infinity.
     */
    bool isValid()
    {
        return depth != -FLT_MAX;
    }
};

/** A structure representing the packed information related to a surface point
 */
struct PackedSurfaceData ///< 32 bytes
{
    uint3 position;         ///< Packed position of the surface point in the world space.
    uint normal;            ///< Packed normal vector at the surface point.
    uint diffuseWeight;     ///< Packed weight of diffuse reflection at the surface point.
    uint specularWeight;    ///< Packed weight of specular reflection at the surface point.
    uint specularRoughness; ///< Packed roughness of the surface contributing to the specular reflection.
    uint depth;             ///< Packed depth (distance from a camera) at the surface point.
};

/** A structure that represents the position, normal, and reflectance properties of a surface point in a scene.
 */
struct SurfaceData
{
    float3 position; ///< The position of the surface point in the world space.
    float3 normal;   ///< The normal vector at the surface point.
    float diffuseWeight;  ///< The weight of diffuse reflection at the surface point.
    float specularWeight; ///< The weight of specular reflection at the surface point.
    float specularRoughness; ///< The roughness of the surface contributing to the specular reflection.
    float depth;             ///< The depth (distance from a camera) at the surface point.

    /** Creates an invalid SurfaceData object, used as a sentinel value.
     */
    static SurfaceData createInvalid()
    {
        SurfaceData surfaceData = {};
        surfaceData.depth = -FLT_MAX;
        return surfaceData;
    }

    /** Creates a SurfaceData object from given shading data, bsdf, and camera position.
     */
    static SurfaceData create(const ShadingData sd, const IBSDF bsdf, const float3 cameraPosition)
    {
        SurfaceData surfaceData;
        surfaceData.position = sd.posW;
        surfaceData.normal = sd.N;
        BSDFProperties bsdfProp = bsdf.getProperties(sd);
        surfaceData.diffuseWeight = luminance(bsdfProp.diffuseReflectionAlbedo);
        surfaceData.specularWeight = luminance(bsdfProp.specularReflectionAlbedo);
        surfaceData.specularRoughness = bsdfProp.roughness;
        surfaceData.depth = distance(sd.posW, cameraPosition);

        return surfaceData;
    }

    /** Unpacks a PackedSurfaceData object to create a SurfaceData object.
     */
    static SurfaceData unpack(const PackedSurfaceData packedSurfaceData)
    {
        SurfaceData surfaceData;
        surfaceData.position = asfloat(packedSurfaceData.position);
        surfaceData.normal = decodeNormal2x16(packedSurfaceData.normal);
        surfaceData.diffuseWeight = asfloat(packedSurfaceData.diffuseWeight);
        surfaceData.specularWeight = asfloat(packedSurfaceData.specularWeight);
        surfaceData.specularRoughness = asfloat(packedSurfaceData.specularRoughness);
        surfaceData.depth = asfloat(packedSurfaceData.depth);

        return surfaceData;
    }

    /** Packs the SurfaceData object into a PackedSurfaceData object for more efficient storage and transfer.
     */
    PackedSurfaceData pack()
    {
        PackedSurfaceData packedSurfaceData = {};
        packedSurfaceData.position = asuint(this.position);
        packedSurfaceData.normal = encodeNormal2x16(this.normal);
        packedSurfaceData.diffuseWeight = asuint(this.diffuseWeight);
        packedSurfaceData.specularWeight = asuint(this.specularWeight);
        packedSurfaceData.specularRoughness = asuint(this.specularRoughness);
        packedSurfaceData.depth = asuint(this.depth);

        return packedSurfaceData;
    }

    /** Evaluates the BRDF (Bidirectional Reflectance Distribution Function), giving the proportion of light reflected along an outgoing direction (wo), given an incoming light direction (wi).
     */
    float evalBRDF(const float3 wi, const float3 wo)
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

    /** Evaluates the target PDF (Probability Density Function) for sampling a specific direction of light given the outgoing direction (wo).
     *  Different cases handle different types of light sources.
     */
    float evalTargetPDF(const LightSample sample, const float3 wo)
    {
        switch (sample.lightType)
        {
        case LightSample::Type::PointLight:
        case LightSample::Type::AreaLight:
            {
                // For point and area lights, we compute a vector from the point to the light,
                // and use this to compute the geometric factor and BRDF weight.
                const float3 pointToLightVec = sample.posDir - position;
                const float distSq = dot(pointToLightVec, pointToLightVec);
                const float3 wi = pointToLightVec / sqrt(distSq);
                const float geometryFactor = max(0.f, dot(-wi, sample.normal)) / distSq;
                const float brdfWeight = evalBRDF(wi, wo);
                return sample.Le * brdfWeight * geometryFactor;
            }
        case LightSample::Type::DistantLight:
            {
                // For distant lights, the direction to the light is constant across the scene,
                // so we simply compute the BRDF weight for this direction.
                const float3 wi = sample.posDir;
                const float brdfWeight = evalBRDF(wi, wo);
                return sample.Le * brdfWeight;
            }
        }
        return 0.f;
    }

    /** Evaluates the visibility of a light sample from the point of view of the surface point.
     *  This is typically used to compute shadowing.
     */
    float evalVisibility(const LightSample lightSample)
    {
        // We create a ray from the surface point to the light sample,
        // and perform a ray query to see if the light sample is visible.
        float3 rayOrigin = computeRayOrigin(this.position, this.normal);
        float3 dirToSample = lightSample.getDirToSample(rayOrigin);
        float distToSample = lightSample.getDistanceToSample(rayOrigin);
        SceneRayQuery<1> rayQuery;
        const Ray ray = Ray(rayOrigin, dirToSample, 0.0001f, distToSample - kShadowRayEpsilon);
		return rayQuery.traceVisibilityRay(ray, RAY_FLAG_NONE, 0xff);
    }

    /** Returns true if the SurfaceData is valid, i.e., if it corresponds to a real surface point in the scene.
     *  The SurfaceData is considered invalid if its depth is -FLT_MAX, a sentinel value.
     */
    bool isValid()
    {
        return depth != -FLT_MAX;
    }
};
