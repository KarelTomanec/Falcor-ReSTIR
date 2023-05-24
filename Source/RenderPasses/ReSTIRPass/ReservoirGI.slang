#include "Utils/Math/MathConstants.slangh"
import Utils.Sampling.TinyUniformSampleGenerator;
import Rendering.Materials.IBSDF;
import Utils.Math.PackedFormats;

struct PackedSampleGI
{
    uint4 surfaceGeometry;
    uint4 sampleGeometry;
    uint Le;
    uint sourcePdf;
    uint valid;
    uint _pad0 = 0;
}

struct SampleGI
{
    float3 surfacePoint;  ///< Visible point.
    float3 surfaceNormal; ///< Surface normal of the visible point
    float3 samplePoint;   ///< Sample point.
    float3 sampleNormal;  ///< Surface normal of the sample.
    float3 Le;            ///< Emission.
    float sourcePdf;      ///< Source PDF of the light sample.
    uint valid = 0;

    static SampleGI unpack(const PackedSampleGI packedSample)
    {
        SampleGI sample = {};

        sample.surfacePoint = asfloat(packedSample.surfaceGeometry.xyz);
        sample.surfaceNormal = decodeNormal2x16(packedSample.surfaceGeometry.w);
        sample.samplePoint = asfloat(packedSample.sampleGeometry.xyz);
        sample.sampleNormal = decodeNormal2x16(packedSample.sampleGeometry.w);
        sample.Le = decodeLogLuvHDR(packedSample.Le);
        sample.sourcePdf = asfloat(packedSample.sourcePdf);
        sample.valid = packedSample.valid;

        return sample;
    }

    PackedSampleGI pack()
    {
        PackedSampleGI packedSample = {};

        packedSample.surfaceGeometry.xyz = asuint(this.surfacePoint);
        packedSample.surfaceGeometry.w = encodeNormal2x16(this.surfaceNormal);
        packedSample.sampleGeometry.xyz = asuint(this.samplePoint);
        packedSample.sampleGeometry.w = encodeNormal2x16(this.sampleNormal);
        packedSample.Le = encodeLogLuvHDR(this.Le);
        packedSample.sourcePdf = asuint(this.sourcePdf);
        packedSample.valid = this.valid;

        return packedSample;
    }
}

struct PackedReservoirGI ///< 64 bytes
{
    PackedSampleGI packedLightSample;
    uint W;
    uint M;
    uint _pad0 = 0;
    uint _pad1 = 0;
};

struct ReservoirGI
{
    SampleGI sample; ///< The output sample.
	float weightSum; ///< The sum of weights.
	float W; ///< The weight of the reservoir.
	uint M; ///< The number of samples seen so far.

	__init()
    {
        this.sample = {};
        this.weightSum = 0;
        this.W = 0;
        this.M = 0;
	}

    [mutating]
    bool update<S : ISampleGenerator>(const SampleGI lightSample, const float targetPDF, const float sourcePDF, inout S sg)
	{
        float weight = targetPDF / sourcePDF;
        this.weightSum += weight;
        this.M += 1;
        bool isSelected = sampleNext1D(sg) * this.weightSum < weight;

		if(isSelected) {
			this.sample = lightSample;
			this.W = targetPDF;
		}

		return isSelected;
	}

    [mutating]
    bool update<S : ISampleGenerator>(inout ReservoirGI reservoir, const float targetPDF, inout S sg)
    {
        float weight = targetPDF * reservoir.W * reservoir.M;
        this.weightSum += weight;
        this.M += reservoir.M;

        bool isSelected = sampleNext1D(sg) * this.weightSum < weight;

        if (isSelected) {
            this.sample = reservoir.sample;
            this.W = targetPDF;
        }

        return isSelected;
    }



    static ReservoirGI unpack(const PackedReservoirGI packedReservoir)
    {
        ReservoirGI reservoir;

        reservoir.sample = SampleGI::unpack(packedReservoir.packedLightSample);
		reservoir.W = asfloat(packedReservoir.W);
        reservoir.M = packedReservoir.M;
        reservoir.weightSum = reservoir.M * reservoir.W;

		if (isinf(reservoir.W) || isnan(reservoir.W))
        {
            reservoir.W = 0.f;
            reservoir.M = 0;
        }

		return reservoir;
	}

    PackedReservoirGI pack()
    {
        PackedReservoirGI packedReservoir = {};
        packedReservoir.packedLightSample = this.sample.pack();
        packedReservoir.W = asuint(this.W);
        packedReservoir.M = this.M;
		return packedReservoir;
	}
};
