#include "Utils/Math/MathConstants.slangh"
import Scene.Scene;
import Utils.Color.ColorHelpers;
import Utils.Sampling.AliasTable;
import Utils.Sampling.SampleGeneratorInterface;
import Utils.Geometry.GeometryHelpers;

import Utils.Math.FormatConversion;
import Utils.Math.MathHelpers;
import Utils.Math.PackedFormats;

struct PackedDirectLightSample ///< 16 bytes
{
    uint2 direction; ///< Packed direction vector of the light source.
    uint Le;         ///< Packed intensity of the light source.
    uint distance;   ///< Packed distance from the surface point to the light source.
}

struct DirectLightSample
{
    float3 direction; ///< The direction vector of the light source.
    float3 Le;        ///< The intensity of the light source.
    float distance;   ///< The distance from the surface point to the light source.

    /** Packs the direct light sample data into a `PackedDirectLightSample` struct.
     *  Uses various encoding methods to convert data to uint format.
     */
    PackedDirectLightSample pack()
    {
        PackedDirectLightSample packedDirectLightSample;

        packedDirectLightSample.direction = encodeNormal3x16(this.direction);
        packedDirectLightSample.Le = encodeLogLuvHDR(this.Le);
        packedDirectLightSample.distance = asuint(this.distance);

        return packedDirectLightSample;
    }

    /** Unpacks the data from a `PackedDirectLightSample` struct into a `DirectLightSample` struct.
     *  Uses various decoding methods to convert data back from uint format.
     */
    static DirectLightSample unpack(const PackedDirectLightSample packedDirectLightSample)
    {
        DirectLightSample directLightSample;

        directLightSample.direction = decodeNormal3x16(packedDirectLightSample.direction);
        directLightSample.Le = decodeLogLuvHDR(packedDirectLightSample.Le);
        directLightSample.distance = asfloat(packedDirectLightSample.distance);

        return directLightSample;
    }
}

struct PackedMinimalLightSample ///< 8 bytes
{
    uint typeIndex; ///< An unsigned integer storing both the type and index of the light.
    uint position;  ///< An unsigned integer representation of the position of the light in the environment.
}

struct MinimalLightSample
{
    static const uint kLightTypeOffset = 30;
    static const uint kIndexMask = (1 << kLightTypeOffset) - 1;
    static const uint kTypeMask = ~kIndexMask;
    static const uint kInvalidSample = 0xffffffff;

    /// Enum class to represent the type of the light.
    enum class Type
    {
        EmissiveGeometry = (0 << kLightTypeOffset), ///< Represents emissive geometry light sources.
        Environment = (1 << kLightTypeOffset),      ///< Represents environment light sources.
        Analytic = (2 << kLightTypeOffset),         ///< Represents analytic light sources.
    };

    uint typeIndex;  ///< Unsigned integer that stores both the type and the index of the light.
    float2 position; ///< Floating point vector storing the position of the light (coordinates inside texel or triangle)

    /// Initialization method for the MinimalLightSample structure.
    __init()
    {
        this.typeIndex = kInvalidSample;
    }

    /// Checks if the light sample is valid or not.
    bool isValid()
    {
        return typeIndex != kInvalidSample;
    }

    // Methods to create different types of MinimalLightSample instances. Each of them sets typeIndex accordingly.
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

    static MinimalLightSample createAnalytic(const uint index, const float2 position)
    {
        MinimalLightSample lightSample = {};
        lightSample.typeIndex = uint(Type::Analytic) | uint(index & kIndexMask);
        lightSample.position = position.x + position.y > 1.f ? 1.f - position : position;
        return lightSample;
    }

    /// Method to convert (pack) the MinimalLightSample into a PackedMinimalLightSample.
    PackedMinimalLightSample pack()
    {
        PackedMinimalLightSample packedLightSample;
        packedLightSample.typeIndex = this.typeIndex;
        packedLightSample.position = packSnorm2x16(this.position);
        return packedLightSample;
    }

    /// Method to convert (unpack) a PackedMinimalLightSample back into a MinimalLightSample.
    static MinimalLightSample unpack(const PackedMinimalLightSample packedLightSample)
    {
        MinimalLightSample lightSample = {};
        lightSample.typeIndex = packedLightSample.typeIndex;
        lightSample.position = unpackSnorm2x16(packedLightSample.position);
        return lightSample;
    }

    /// Returns the type of the light sample.
    MinimalLightSample::Type getType()
    {
        return MinimalLightSample::Type(typeIndex & kTypeMask);
    }

    /// Returns the index of the light sample in alias table
    uint getIndex()
    {
        return typeIndex & kIndexMask;
    }

    /// Returns the position of the light sample.
    float2 getPosition()
    {
        return position;
    }

    /// Returns the direction to the environment light sample.
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
    PackedMinimalLightSample packedMinLightSample; ///< Compact representation of the minimal light sample.
    uint pdf;                                      ///< Unsigned integer representation of the PDF of the light sample.
    uint Le;                                       ///< Unsigned integer representation of the emission of the light sample.
    uint3 posDir;                                  ///< Unsigned integer representation of the position/direction of the light.
    uint normal;                                   ///< Unsigned integer representation of the normal at the light sample point.
};

struct LightSample
{
    /// Enum class to represent the type of the light sample.
    enum class Type
    {
        AreaLight,    ///< Represents an area light source.
        DistantLight, ///< Represents a distant light source.
        PointLight,   ///< Represents a point light source.
    };

    MinimalLightSample minLightSample;  ///< Minimal light sample - type, index, position.
    Type lightType;                     ///< Type of light (Area, Distant, Point).
    float3 posDir;                      ///< Position or direction (depends on type).
    float3 normal;                      ///< Normal vector at the sample point.
    float pdf;                          ///< Source PDF of the light sample.
    float Le;                           ///< Emission.

    /// Method to convert (pack) the LightSample into a PackedLightSample.
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

    /// Method to convert (unpack) a PackedLightSample back into a LightSample.
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
        case MinimalLightSample::Type::Analytic:
            switch (gScene.getLight(lightSample.minLightSample.getIndex()).type)
            {
            case LightType::Distant:
                lightSample.lightType = LightSample::Type::DistantLight;
                break;
            case LightType::Point:
                lightSample.lightType = LightSample::Type::PointLight;
                break;
            }
            break;
        }
        lightSample.posDir = asfloat(packedLightSample.posDir);
        lightSample.normal = decodeNormal2x16(packedLightSample.normal);
        lightSample.pdf = asfloat(packedLightSample.pdf);
        lightSample.Le = asfloat(packedLightSample.Le);

        return lightSample;
    }

    /// Returns the distance from a given position to the light sample.
    float getDistanceToSample(const float3 position) {
        switch (lightType)
        {
        case LightSample::Type::PointLight:
        case LightSample::Type::AreaLight:
            return distance(position, posDir);
        case LightSample::Type::DistantLight:
            return FLT_MAX;
        }
        return 0;
    }

    /// Returns the direction from a given position to the light sample.
    float3 getDirToSample(const float3 position) {
        switch (lightType)
        {
        case LightSample::Type::PointLight:
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
    /// Weights of light samples for different types of light sources.
    static const float emissiveGeometrySampleWeight = float(LIGHT_TILE_EMISSIVE_SAMPLE_COUNT) / float(LIGHT_TILE_SIZE);
    static const float environmentSampleWeight = float(LIGHT_TILE_ENVIRONMENT_SAMPLE_COUNT) / float(LIGHT_TILE_SIZE);
    static const float analyticLightSampleWeight = float(LIGHT_TILE_ANALYTIC_SAMPLE_COUNT) / float(LIGHT_TILE_SIZE);

    AliasTable emissiveGeometryAliasTable;   ///< Alias table for emissive geometry light sampling.
    Buffer<float> environmentLuminanceTable; ///< Buffer to store luminance for environment light sampling.
    AliasTable environmentAliasTable;        ///< Alias table for environment light sampling.
    AliasTable analyticLightsAliasTable;     ///< Alias table for analytic light sampling.

    /// Methods to sample different types of lights from alias tables.
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

    LightSample sampleAnalytic<S : ISampleGenerator>(inout S sg)
    {
        float binRandom = sampleNext1D(sg);
        float thresholdRandom = sampleNext1D(sg);
        float2 positionRandom = sampleNext2D(sg);
        MinimalLightSample minLightSample = MinimalLightSample::createAnalytic(analyticLightsAliasTable.sample(float2(binRandom, thresholdRandom)), positionRandom);
        return getAnalyticLightSample(minLightSample);
    }

    /// Retrieves a light sample based on a given minimal light sample.
    LightSample getLightSample(const MinimalLightSample minLightSample)
    {

        switch (minLightSample.getType())
        {
        case MinimalLightSample::Type::EmissiveGeometry:
            return getEmissiveLightSample(minLightSample);
        case MinimalLightSample::Type::Environment:
            return getEnvironmentLightSample(minLightSample);
        case MinimalLightSample::Type::Analytic:
            return getAnalyticLightSample(minLightSample);
        }
        LightSample lightSample;
        return lightSample;
    }

    /// Methods to get specific types of light samples based on a minimal light sample.
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
        lightSample.normal = -lightSample.posDir;
        const uint texelIndex = minLightSample.getIndex();
        lightSample.Le = environmentLuminanceTable[texelIndex];
        lightSample.pdf = environmentSampleWeight * lightSample.Le / environmentAliasTable.weightSum;

        return lightSample;
    }

    LightSample getAnalyticLightSample(const MinimalLightSample minLightSample)
    {
        LightSample lightSample;

        lightSample.minLightSample = minLightSample;

        const uint index = minLightSample.getIndex();
        const LightData analyticLight = gScene.getLight(index);
        switch (analyticLight.type)
        {
            case LightType::Point:
            {
                lightSample.lightType = LightSample::Type::PointLight;
                lightSample.posDir = analyticLight.posW;
                break;
            }
            case LightType::Directional:
            {
                lightSample.lightType = LightSample::Type::DistantLight;
                lightSample.posDir = -analyticLight.dirW;
                break;
            }
        }
        lightSample.normal = -lightSample.posDir;
        lightSample.Le = luminance(analyticLight.intensity);
        lightSample.pdf = analyticLightSampleWeight * lightSample.Le / analyticLightsAliasTable.weightSum;

        return lightSample;
    }

    /// Retrieves the radiance of a light sample given a minimal light sample.
    float3 getLightSampleRadiance(const MinimalLightSample minLightSample)
    {
        switch (minLightSample.getType())
        {
        case MinimalLightSample::Type::EmissiveGeometry:
            return gScene.lightCollection.getAverageRadiance(minLightSample.getIndex());
        case MinimalLightSample::Type::Environment:
            float3 dir = minLightSample.getEnvironmentDir();
            return gScene.envMap.eval(dir);
        case MinimalLightSample::Type::Analytic:
            return gScene.getLight(minLightSample.getIndex()).intensity;
        }
        return float3(0.f);
    }
};
