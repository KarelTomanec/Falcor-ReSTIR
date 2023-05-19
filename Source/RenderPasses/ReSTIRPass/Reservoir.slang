#include "Utils/Math/MathConstants.slangh"
import Utils.Sampling.TinyUniformSampleGenerator;
import Rendering.Materials.IBSDF;

import LightSampler;

struct PackedReservoir ///< 16 bytes
{
    PackedMinimalLightSample packedLightSample;
    uint W;
    uint M;
};

struct Reservoir
{
    MinimalLightSample sample;      ///< The output sample.
	float weightSum;                ///< The sum of weights.
	float W;                        ///< The weight of the reservoir.
	uint M;                        ///< The number of samples seen so far.

	__init()
    {
        this.sample = {};
        this.weightSum = 0;
        this.W = 0;
        this.M = 0;
	}

    [mutating]
    bool update<S : ISampleGenerator>(const MinimalLightSample lightSample, const float targetPDF, const float sourcePDF, inout S sg)
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
	bool update<S : ISampleGenerator>(inout Reservoir reservoir, const float targetPDF, inout S sg)
	{
        float weight = targetPDF * reservoir.W * reservoir.M;
        this.weightSum += weight;
		this.M += reservoir.M;

        bool isSelected = sampleNext1D(sg) * this.weightSum < weight;

		if(isSelected) {
			this.sample = reservoir.sample;
			this.W = targetPDF;
		}

		return isSelected;
	}

	static Reservoir unpack(const PackedReservoir packedReservoir)
	{
		Reservoir reservoir;

        reservoir.sample = MinimalLightSample::unpack(packedReservoir.packedLightSample);
		reservoir.W = asfloat(packedReservoir.W);
        reservoir.M = packedReservoir.M;

		if (isinf(reservoir.W) || isnan(reservoir.W))
        {
            reservoir.W = 0.f;
            reservoir.M = 0;
        }

		return reservoir;
	}

	PackedReservoir pack()
	{
        PackedReservoir packedReservoir;
        packedReservoir.packedLightSample = this.sample.pack();
        packedReservoir.W = asuint(this.W);
        packedReservoir.M = this.M;
		return packedReservoir;
	}
};
