import LightSampler;
import Utils.Sampling.TinyUniformSampleGenerator;

struct CreateLightTilesPass
{
    // Static:
    static const uint kLightTileCount = LIGHT_TILE_COUNT; ///< Number of light tiles.
    static const uint kLightTileSize = LIGHT_TILE_SIZE;   ///< Number of light samples in the tile.
    static const uint kLightTileEmissiveSampleCount = LIGHT_TILE_EMISSIVE_SAMPLE_COUNT; ///< Number of emissive geometry light samples in the tile.
    static const uint kLightTileEnvironmentSampleCount = LIGHT_TILE_ENVIRONMENT_SAMPLE_COUNT; ///< Number of environment light samples in the tile.
    static const uint kLightTileAnalyticSampleCount = LIGHT_TILE_ANALYTIC_SAMPLE_COUNT; ///< Number of analytic light samples in the tile.

    LightSampler gLightSampler; ///< Custom light wrapper for sampling various kinds of lights (EmissiveGeometry, Environment, ...).

    // Resources:
    RWStructuredBuffer<PackedLightSample> gLightTiles; ///< Output samples saved as light tiles.

	uint    gFrameCount; ///< Frame count since scene was loaded.

	void execute(const uint2 threadId)
	{
        // Tile index.
        uint tileIndex = threadId.y;
        // Sample index inside the tile.
        uint inTileSampleIndex = threadId.x;

        if (tileIndex >= kLightTileCount || inTileSampleIndex >= kLightTileSize) return;

        // Get buffer index where the selected sample will be saved.
        uint bufferIndex = tileIndex * kLightTileSize + inTileSampleIndex;

        TinyUniformSampleGenerator sg = TinyUniformSampleGenerator(bufferIndex, gFrameCount);

        // Sample from the alias table.
        LightSample lightSample;
        if (inTileSampleIndex < kLightTileEmissiveSampleCount)
        {
            // The first part of the light tile consists of emissive geometry samples.
            lightSample = gLightSampler.sampleEmissiveGeometry(sg);
        }
        else if (inTileSampleIndex < kLightTileEmissiveSampleCount + kLightTileEnvironmentSampleCount)
        {
            // The second part of the light tile consists of environment map samples.
            lightSample = gLightSampler.sampleEnvironment(sg);
        }
        else if (inTileSampleIndex < kLightTileEmissiveSampleCount + kLightTileEnvironmentSampleCount + kLightTileAnalyticSampleCount)
        {
            // The third part of the light tile consists of analytic samples.
            lightSample = gLightSampler.sampleAnalytic(sg);
        }
        // Pack and save selected sample.
        gLightTiles[bufferIndex] = lightSample.pack();
	}
};

cbuffer CB
{
	CreateLightTilesPass gCreateLightTilesPass;
}

[numthreads(256, 1, 1)]
void main(uint3 dispatchThreadId : SV_DispatchThreadID)
{
    gCreateLightTilesPass.execute(dispatchThreadId.xy);
}
