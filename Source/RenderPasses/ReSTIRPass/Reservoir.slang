#include "Utils/Math/MathConstants.slangh"
import Utils.Sampling.TinyUniformSampleGenerator;
import Rendering.Materials.IBSDF;

import LightSampler;

/** This structure is used to pack the reservoir data into a more efficient format using only 16 bytes.
 */
struct PackedReservoir
{
    PackedMinimalLightSample packedLightSample; ///< Packed minimal light sample
    uint W;                                     ///< Packed reservoir weight
    uint M;                                     ///< Packed number of samples
};

/** This structure represents a reservoir that holds one sample selected from a larger set. It also stores metadata about how it was constructed, specifically the number
 *  of candidates evaluated during its construction (M), their total weight (weightSum) and the current weight of the reservoir (W).
 */
struct Reservoir
{
    MinimalLightSample sample;      ///< Output light sample.
	float weightSum;                ///< Sum of weights.
	float W;                        ///< Weight of the reservoir.
	uint M;                         ///< Number of samples seen so far.

    /** Sets up a reservoir with no samples, zero weights and sample count.
     */
	__init()
    {
        this.sample = {};
        this.weightSum = 0;
        this.W = 0;
        this.M = 0;
    }

    /** Updates the reservoir with a new light sample.
     *
     * \param[in] lightSample New minimal light sample to consider for addition in the reservoir.
     * \param[in] targetPDF Target PDF of the light sample (doesn't have to be normalized).
     * \param[in] sourcePDF Source PDF of the light sample [0, 1].
     * \param[in, out] sg Sample generator to be used for selection process.
     *
     * \return Indicates whether the new sample was selected for the reservoir.
     */
    [mutating]
    bool update<S : ISampleGenerator>(const MinimalLightSample lightSample, const float targetPDF, const float sourcePDF, inout S sg)
	{
        float weight = targetPDF / sourcePDF;
        this.weightSum += weight;
        this.M += 1u;
        bool isSelected = sampleNext1D(sg) * this.weightSum < weight;

		if(isSelected) {
			this.sample = lightSample;
			this.W = targetPDF;
		}

		return isSelected;
	}

    /** Combine the current reservoir with another reservoir (merge).
     *
     * \param[in, out] reservoir Another reservoir to consider for merging.
     * \param[in] targetPDF Target PDF of the light sample (doesn't have to be normalized).
     * \param[in, out] sg Sample generator to be used for selection process.
     *
     * \return Indicates whether the new sample was selected for the reservoir.
     */
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

    /**
     * Unpacks a PackedReservoir into a Reservoir.
     *
     * This function unpacks a PackedReservoir, transforming its compact data into the
     * corresponding data in a Reservoir. If the unpacked weight is infinite or NaN,
     * the weight and count of samples are reset to zero.
     *
     * \param[in] packedReservoir The packed reservoir to be unpacked.
     *
     * \return Reservoir The unpacked reservoir.
     */
	static Reservoir unpack(const PackedReservoir packedReservoir)
	{
		Reservoir reservoir;

        reservoir.sample = MinimalLightSample::unpack(packedReservoir.packedLightSample);
		reservoir.W = asfloat(packedReservoir.W);
        reservoir.M = packedReservoir.M;

		if (isinf(reservoir.W) || isnan(reservoir.W))
        {
            reservoir.W = 0.f;
            reservoir.M = 0u;
        }

		return reservoir;
    }

    /**
     * Packs the current Reservoir into a PackedReservoir.
     *
     * \return PackedReservoir The packed version of the current reservoir.
     */
	PackedReservoir pack()
	{
        PackedReservoir packedReservoir;
        packedReservoir.packedLightSample = this.sample.pack();
        packedReservoir.W = asuint(this.W);
        packedReservoir.M = this.M;
		return packedReservoir;
	}
};
