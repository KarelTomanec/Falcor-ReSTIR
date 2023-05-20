#include "Utils/Math/MathConstants.slangh"
#include "Scene/SceneDefines.slangh"
import Scene.Raytracing;
import Scene.Intersection;

import Utils.Color.ColorHelpers;
import Rendering.Materials.IBSDF;
import Scene.Material.ShadingUtils;

import Utils.Math.BitTricks;

// Shadow ray epsilon is a small value used to nudge the shadow ray origin along the normal
// to avoid self-intersection due to numerical precision issues.
static const float kShadowRayEpsilon = 0.0001f;

// Thresholds for determining valid neighboring pixels in terms of normal and depth similarity.
static const float kNormalThreshold = NORMAL_THRESHOLD;
static const float kDepthThreshold = DEPTH_THRESHOLD;

/** Check if a neighboring pixel is valid based on the similarity of their normal vectors and depth values.
 */
bool isValidNeighbor(float3 norm, float3 neighborNorm, float depth, float neighborDepth, float normalThreshold, float depthThreshold)
{
    // Check if the cosine of the angle between the normals is above the threshold and
    // if the relative difference in depth is within the threshold.
    return (dot(norm, neighborNorm) >= normalThreshold) && abs(depth - neighborDepth) <= depthThreshold * max(depth, neighborDepth);
}

bool isValidNeighbor(float3 norm, float3 neighborNorm, float depth, float neighborDepth)
{
    return isValidNeighbor(norm, neighborNorm, depth, neighborDepth, kNormalThreshold, kDepthThreshold);
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
    // Initialize shading data.
    sd = {};

    // Compute the direction of the ray from the camera to the pixel.
    const float3 rayDir = camera.computeRayPinhole(pixel, frameDim).dir;
    bool valid = false;

    // Retrieve the hit info for the pixel.
    const HitInfo hit = HitInfo(vbuffer[pixel]);

    // Check if the hit info is valid and if the hit was a triangle.
    if (hit.isValid() && hit.getType() == HitType::Triangle)
    {
        const TriangleHit triangleHit = hit.getTriangleHit();

        // Evaluate Falcor's material parameters at the hit point.
        // TODO: Implement texLOD to enable texture filtering in prepareShadingData().
        const VertexData v = gScene.getVertexData(triangleHit);
        const uint materialID = gScene.getMaterialID(triangleHit.instanceID);
        sd = gScene.materials.prepareShadingData(v, materialID, -rayDir, lod);

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

/** Compute a linear index for a 2D buffer.
 */
uint getBufferIndex(uint2 pixel, uint2 frameDim)
{
	return pixel.y * frameDim.x + pixel.x;
}

/** Sample a random neighboring pixel within a given radius.
 */
uint2 getRandomNeighborPixel<S : ISampleGenerator>(uint2 pixel, inout S sg, float radius = SPATIAL_REUSE_SAMPLE_RADIUS)
{
    // Generate a random point within the radius around the current pixel using polar coordinates.
    // rho and theta are respectively the radius and angle of the polar coordinates.

    float rho = radius * sqrt(sampleNext1D(sg));
    float theta = 2.0f * M_PI * sampleNext1D(sg);

    // Convert the polar coordinates to Cartesian coordinates.
    float2 randomPixel = pixel;
    randomPixel.x += rho * cos(theta);
    randomPixel.y += rho * sin(theta);

    // Return the random neighboring pixel after rounding to the nearest integer value, because pixel coordinates are integers.
    return uint2(round(randomPixel));
}
