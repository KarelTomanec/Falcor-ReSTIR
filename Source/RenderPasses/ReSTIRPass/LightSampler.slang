#include "Utils/Math/MathConstants.slangh"
import Scene.Scene;
import Utils.Color.ColorHelpers;
import Utils.Sampling.AliasTable;
import Utils.Sampling.SampleGeneratorInterface;
import Utils.Geometry.GeometryHelpers;

import Utils.Math.FormatConversion;
import Utils.Math.MathHelpers;
import Utils.Math.PackedFormats;

typedef uint2 PackedMinimalLightSample; ///< 8 bytes

struct MinimalLightSample
{
    static const uint kLightTypeOffset = 30;
    static const uint kIndexMask = (1 << kLightTypeOffset) - 1;
    static const uint kTypeMask = ~kIndexMask;
    static const uint kInvalidSample = 0xffffffff;

    enum class Type
    {
        EmissiveGeometry = (0 << kLightTypeOffset),
        Environment = (1 << kLightTypeOffset),
        // TODO: Analytic = (2 << kLightTypeOffset),
    };

    uint typeIndex;
    float2 position;

    __init()
    {
        this.typeIndex = kInvalidSample;
    }

    bool isValid()
    {
        return typeIndex != kInvalidSample;
    }

    static MinimalLightSample createEmissive(const uint index, const float2 position)
    {
        MinimalLightSample lightSample = {};
        lightSample.typeIndex = uint(Type::EmissiveGeometry) | uint(index & kIndexMask);
        lightSample.position = position.x + position.y > 1.f ? 1.f - position : position;
        return lightSample;
    }

    static MinimalLightSample createEnvironment(const uint index, const float2 position)
    {
        MinimalLightSample lightSample = {};
        lightSample.typeIndex = uint(Type::Environment) | uint(index & kIndexMask);
        lightSample.position = position.x + position.y > 1.f ? 1.f - position : position;
        return lightSample;
    }

    PackedMinimalLightSample pack()
    {
        PackedMinimalLightSample packedLightSample = uint2(this.typeIndex, packSnorm2x16(this.position));
        return packedLightSample;
    }

    static MinimalLightSample unpack(const PackedMinimalLightSample packedLightSample)
    {
        MinimalLightSample lightSample = {};
        lightSample.typeIndex = packedLightSample.x;
        lightSample.position = unpackSnorm2x16(packedLightSample.y);
        return lightSample;
    }

    MinimalLightSample::Type getType()
    {
        return MinimalLightSample::Type(typeIndex & kTypeMask);
    }

    uint getIndex()
    {
        return typeIndex & kIndexMask;
    }

    float2 getPosition()
    {
        return position;
    }

    float3 getEnvironmentDir()
    {
        // Get index of the texel in environment map
        uint texelIndex = getIndex();
        // Get relative position of the sample point inside the texel
        float2 position = getPosition();
        // Get environment texture dimensions
        uint2 dimension = gScene.envMap.getDimensions();
        // Compute texture uv -> [0, 1]^2
        float2 uv = (float2(texelIndex % dimension.x, texelIndex / dimension.x) + position) / dimension;
        return gScene.envMap.toWorld(latlong_map_to_world(uv));
    }

};

struct PackedLightSample ///< 32 bytes
{
    PackedMinimalLightSample packedMinLightSample;
    uint pdf;
    uint Le;
    uint3 posDir;
    uint normal;
};

struct LightSample
{
    enum class Type
    {
        AreaLight,
        DistantLight,
        // TODO: Point,
    };

    MinimalLightSample minLightSample;
    Type lightType;
    float3 posDir;
    float3 normal;
    float pdf;
    float Le;

    PackedLightSample pack()
    {
        PackedLightSample packedLightSample;

        packedLightSample.packedMinLightSample = minLightSample.pack();
        packedLightSample.posDir = asuint(posDir);
        packedLightSample.normal = encodeNormal2x16(normal);
        packedLightSample.pdf = asuint(pdf);
        packedLightSample.Le = asuint(Le);

        return packedLightSample;
    }

    static LightSample unpack(const PackedLightSample packedLightSample)
    {
        LightSample lightSample;
        lightSample.minLightSample = MinimalLightSample::unpack(packedLightSample.packedMinLightSample);
        MinimalLightSample::Type type = lightSample.minLightSample.getType();
        switch (type)
        {
        case MinimalLightSample::Type::EmissiveGeometry:
            lightSample.lightType = LightSample::Type::AreaLight;
            break;
        case MinimalLightSample::Type::Environment:
            lightSample.lightType = LightSample::Type::DistantLight;
            break;
        }
        lightSample.posDir = asfloat(packedLightSample.posDir);
        lightSample.normal = decodeNormal2x16(packedLightSample.normal);
        lightSample.pdf = asfloat(packedLightSample.pdf);
        lightSample.Le = asfloat(packedLightSample.Le);

        return lightSample;
    }

    float getDistanceToSample(const float3 position) {
        switch (lightType)
        {
        case LightSample::Type::AreaLight:
            return distance(position, posDir);
        case LightSample::Type::DistantLight:
            return FLT_MAX;
        }
        return 0;
    }

    float3 getDirToSample(const float3 position) {
        switch (lightType)
        {
        case LightSample::Type::AreaLight:
            return normalize(posDir - position);
        case LightSample::Type::DistantLight:
            return posDir;
        }
        return float3(0.f);
    }
};

struct LightSampler
{

    static const float emissiveGeometrySampleWeight = float(LIGHT_TILE_EMISSIVE_SAMPLE_COUNT) / float(LIGHT_TILE_SIZE);
    static const float environmentSampleWeight = float(LIGHT_TILE_ENVIRONMENT_SAMPLE_COUNT) / float(LIGHT_TILE_SIZE);


    AliasTable emissiveGeometryAliasTable;

    Buffer<float> environmentLuminanceTable;
    AliasTable environmentAliasTable;

    LightSample sampleEmissiveGeometry<S : ISampleGenerator>(inout S sg)
    {
        float binRandom = sampleNext1D(sg);
        float thresholdRandom = sampleNext1D(sg);
        float2 positionRandom = sampleNext2D(sg);
        MinimalLightSample minLightSample = MinimalLightSample::createEmissive(emissiveGeometryAliasTable.sample(float2(binRandom, thresholdRandom)), positionRandom);
        return getEmissiveLightSample(minLightSample);
    }

    LightSample sampleEnvironment<S : ISampleGenerator>(inout S sg)
    {
        float binRandom = sampleNext1D(sg);
        float thresholdRandom = sampleNext1D(sg);
        float2 positionRandom = sampleNext2D(sg);
        MinimalLightSample minLightSample = MinimalLightSample::createEnvironment(environmentAliasTable.sample(float2(binRandom, thresholdRandom)), positionRandom);
        return getEnvironmentLightSample(minLightSample);
    }

    LightSample getLightSample(const MinimalLightSample minLightSample)
    {

        switch (minLightSample.getType())
        {
        case MinimalLightSample::Type::EmissiveGeometry:
            return getEmissiveLightSample(minLightSample);
        case MinimalLightSample::Type::Environment:
            return getEnvironmentLightSample(minLightSample);
        }
        LightSample lightSample;
        return lightSample;
    }

    LightSample getEmissiveLightSample(const MinimalLightSample minLightSample)
    {
        LightSample lightSample;

        lightSample.minLightSample = minLightSample;
        lightSample.lightType = LightSample::Type::AreaLight;

        const uint index = minLightSample.getIndex();
        const EmissiveTriangle triangle = gScene.lightCollection.getTriangle(index);

        const float2 position = minLightSample.getPosition();
        const float3 barycentrics = float3(1.f - position.x - position.y, position.x, position.y);
        lightSample.posDir = computeRayOrigin(triangle.getPosition(barycentrics), triangle.normal);
        lightSample.normal = triangle.normal;
        lightSample.Le = luminance(gScene.lightCollection.getAverageRadiance(index));
        lightSample.pdf = emissiveGeometrySampleWeight * lightSample.Le / emissiveGeometryAliasTable.weightSum;

        return lightSample;
    }

    LightSample getEnvironmentLightSample(const MinimalLightSample minLightSample)
    {
        LightSample lightSample;

        lightSample.minLightSample = minLightSample;
        lightSample.lightType = LightSample::Type::DistantLight;

        lightSample.posDir = minLightSample.getEnvironmentDir();
        const uint texelIndex = minLightSample.getIndex();
        lightSample.Le = environmentLuminanceTable[texelIndex];
        lightSample.pdf = environmentSampleWeight * lightSample.Le / environmentAliasTable.weightSum;

        return lightSample;
    }

    float3 getLightSampleRadiance(const MinimalLightSample minLightSample)
    {
        switch (minLightSample.getType())
        {
        case MinimalLightSample::Type::EmissiveGeometry:
            return gScene.lightCollection.getAverageRadiance(minLightSample.getIndex());
        case MinimalLightSample::Type::Environment:
            float3 dir = minLightSample.getEnvironmentDir();
            return gScene.envMap.eval(dir);
        }
        return float3(0.f);
    }
};
