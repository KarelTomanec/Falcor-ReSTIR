#include "Utils/Math/MathConstants.slangh"
#include "Scene/SceneDefines.slangh"
import Scene.Raytracing;
import Scene.Intersection;

import Utils.Color.ColorHelpers;
import Rendering.Materials.IBSDF;
import Scene.Material.ShadingUtils;

import Utils.Math.BitTricks;

static const float kShadowRayEpsilon = 0.0001f;

static const float kNormalThreshold = NORMAL_THRESHOLD;
static const float kDepthThreshold = DEPTH_THRESHOLD;

bool isValidNeighbor(float3 norm, float3 neighborNorm, float depth, float neighborDepth)
{
    return (dot(norm, neighborNorm) >= kNormalThreshold) && abs(depth - neighborDepth) <= kDepthThreshold * max(depth, neighborDepth);
}

bool isValidNeighbor(float3 norm, float3 neighborNorm, float depth, float neighborDepth, float normalThreshold, float depthThreshold)
{
    return (dot(norm, neighborNorm) >= normalThreshold) && abs(depth - neighborDepth) <= depthThreshold * max(depth, neighborDepth);
}

/** Helper for setting up the ShadingData struct based on loaded data.
    \param[in] pixel Current pixel coordinates.
    \param[in] frameDim Frame dimensions in pixel.
    \param[in] camera Current camera.
    \param[in] vbuffer VBuffer texture.
    \param[in] lod Method for computing texture level-of-detail.
    \param[out] sd ShadingData struct.
    \return True if the pixel has valid data (not a background pixel). Note sd.V is always valid.
*/
bool loadShadingData(const uint2 pixel, const uint2 frameDim, const Camera camera, Texture2D<PackedHitInfo> vbuffer, const ITextureSampler lod, out ShadingData sd)
{
    sd = {};

    const float3 rayDir = camera.computeRayPinhole(pixel, frameDim).dir;
    bool valid = false;

    const HitInfo hit = HitInfo(vbuffer[pixel]);
    if (hit.isValid() && hit.getType() == HitType::Triangle)
    {
        const TriangleHit triangleHit = hit.getTriangleHit();

        // Evaluate Falcor's material parameters at the hit point.
        // TODO: Implement texLOD to enable texture filtering in prepareShadingData().
        const VertexData v = gScene.getVertexData(triangleHit);
        const uint materialID = gScene.getMaterialID(triangleHit.instanceID);
        sd = gScene.materials.prepareShadingData(v, materialID, -rayDir, lod);

		// FIXME:
        // Adjust shading normals if GBuffer pass has flag enabled.
// #if GBUFFER_ADJUST_SHADING_NORMALS
        // adjustShadingNormal(sd, v);
// #endif
        adjustShadingNormal(sd, v);
        valid = true;
    }

    sd.V = -rayDir;
    return valid;
}

/** Returns the primary ray's direction.
*/
float3 getPrimaryRayDir(uint2 launchIndex, uint2 launchDim, const Camera camera)
{
        return camera.computeRayPinhole(launchIndex, launchDim).dir;
}

uint getBufferIndex(uint2 pixel, uint2 frameDim) {
	return pixel.y * frameDim.x + pixel.x;
}

uint2 getRandomNeighborPixel<S : ISampleGenerator>(uint2 pixel, inout S sg, float radius = SPATIAL_REUSE_SAMPLE_RADIUS)
{
    float rho = radius * sqrt(sampleNext1D(sg));
    float theta = 2.0f * M_PI * sampleNext1D(sg);
    float2 randomPixel = pixel;
    randomPixel.x += rho * cos(theta);
    randomPixel.y += rho * sin(theta);

    return uint2(round(randomPixel));
}
