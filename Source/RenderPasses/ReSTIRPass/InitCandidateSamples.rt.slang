/***************************************************************************
 # Copyright (c) 2015-22, NVIDIA CORPORATION. All rights reserved.
 #
 # Redistribution and use in source and binary forms, with or without
 # modification, are permitted provided that the following conditions
 # are met:
 #  * Redistributions of source code must retain the above copyright
 #    notice, this list of conditions and the following disclaimer.
 #  * Redistributions in binary form must reproduce the above copyright
 #    notice, this list of conditions and the following disclaimer in the
 #    documentation and/or other materials provided with the distribution.
 #  * Neither the name of NVIDIA CORPORATION nor the names of its
 #    contributors may be used to endorse or promote products derived
 #    from this software without specific prior written permission.
 #
 # THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS "AS IS" AND ANY
 # EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 # IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
 # PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
 # CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
 # EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 # PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 # PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
 # OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 # (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
 # OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 **************************************************************************/

/** Minimal path tracer.

    The purpose is to use it for validation of more complex renderers.
    The implementation here should be kept as simple/naive as possible.

    At each hit point (including the primary hit loaded from the V-buffer),
    analytic light sources (point, directional) are sampled uniformly using
    1 shadow ray, and 1 scatter ray is traced to sample the hemisphere.
    At hit/miss the scatter ray includes light from emissive surface and
    the environment map, respectively. Traversal stops at a fixed path length.

    Each type of light (analytic, emissive, env map) can be individually
    enabled/disabled from the host. This clutters the code a bit, but it is
    important as not all other renderes may support all three light types.

    The host sets the following defines:

    MAX_BOUNCES             Maximum number of indirect bounces (0 means no indirect).
    COMPUTE_DIRECT          Nonzero if direct illumination should be included.
    USE_IMPORTANCE_SAMPLING Nonzero if importance sampling should be used for sampling materials.
    USE_ANALYTIC_LIGHTS     Nonzero if Falcor's analytic lights should be used.
    USE_EMISSIVE_LIGHTS     Nonzero if emissive geometry should be used as lights.
    USE_ENV_LIGHT           Nonzero if env map is available and should be used as light source.
    USE_ENV_BACKGROUND      Nonzero if env map is available and should be used as background.
    is_valid_<name>         1 if optional I/O buffer with this name should be used.
*/

#include "Scene/SceneDefines.slangh"
#include "Utils/Math/MathConstants.slangh"

import Scene.Raytracing;
import Scene.Intersection;
import Utils.Math.MathHelpers;
import Utils.Geometry.GeometryHelpers;
import Utils.Sampling.TinyUniformSampleGenerator;
import Rendering.Lights.LightHelpers;
import Utils.Color.ColorHelpers;

import Rendering.Lights.EmissiveLightSampler;
import Rendering.Lights.EmissiveLightSamplerHelpers;
import Rendering.Lights.EmissivePowerSampler;
import Rendering.Lights.EnvMapSampler;

import Reservoir;
import PixelContext;
import HelperFunctions;

cbuffer CB
{
    uint        gFrameCount;        // Frame count since scene was loaded.
    uint        gPRNGDimension;     // First available PRNG dimension.
	EmissiveLightSampler gEmissiveLightSampler;
    EnvMapSampler gEnvMapSampler;                    ///< Environment map sampler. Only valid when kUseEnvLight == true.
}

// Inputs
Texture2D<PackedHitInfo> gVBuffer;
Texture2D<float4> gViewW; // Optional

// Outputs
RWStructuredBuffer<PackedReservoir> gReservoirs;
RWTexture2D<float4> gDebug;

// Static configuration based on defines set from the host.
#define is_valid(name) (is_valid_##name != 0)

static const bool kUseAnalyticLights = USE_ANALYTIC_LIGHTS;
static const bool kUseEmissiveLights = USE_EMISSIVE_LIGHTS;
static const bool kUseEnvLight = USE_ENV_LIGHT;
static const bool kUseEnvBackground = USE_ENV_BACKGROUND;
static const float3 kDefaultBackgroundColor = float3(0, 0, 0);
static const float kRayTMax = FLT_MAX;

/** ReSTIR algorithm
*/
static const uint kLocalLightCandidateCount = LOCAL_LIGHT_CANDIDATE_COUNT;

Reservoir RIS(const uint2 pixel, const uint2 frameDim) 
{
	Reservoir r;
	const HitInfo hit = HitInfo(gVBuffer[pixel]);
	if(hit.isValid())
	{
		// Pixel represents a valid primary hit. Compute its contribution.
		
		const float3 primaryRayOrigin = gScene.camera.getPosition();
		const float3 primaryRayDir = getPrimaryRayDir(pixel, frameDim, gScene.camera);
	
		let lod = ExplicitLodTextureSampler(0.f);

		// Load shading data.
		ShadingData sd = loadShadingData(hit, primaryRayOrigin, primaryRayDir, lod);
		
		// Create BSDF instance at shading point.
		let bsdf = gScene.materials.getBSDF(sd, lod);
		
		// Create sample generator.
		TinyUniformSampleGenerator sg = TinyUniformSampleGenerator(pixel, gFrameCount);
		
		PixelContext pixelContext = PixelContext::create(sd, bsdf);
		
		// Compute ray origin for new rays spawned from the G-buffer.
		float3 rayOrigin =  sd.computeNewRayOrigin();
	
		[unroll]
		for(uint i = 0; i < kLocalLightCandidateCount; i++) 
		{
			// Generate x_i ~ p
			
			Sample ls;
			float3 direction;
			float sourcePDF;
			float sampleDistance;
			
			// Generate emissive sample:
			TriangleLightSample tls;
			if (!gEmissiveLightSampler.sampleLight(rayOrigin, sd.N, true, sg, tls)) {
				r.M += 1;
				continue;
			}
			if(dot(sd.N, tls.dir) < kMinCosTheta) {
				r.M += 1; 
				continue;
			}
			ls.Lo = tls.Le;
			ls.pointS = tls.posW;
			ls.normalS = tls.normalW;
			direction = tls.dir;
			sourcePDF = tls.pdf;
			sampleDistance = distance(sd.posW, tls.posW);
				
			// // Generate environment sample
			// EnvMapSample tls;
			// if (!gEnvMapSampler.sample(sampleNext2D(sg), tls)) {
				// r.M += 1;
				// continue;
			// }
			// ls.Lo = tls.Le;
			// ls.pointS = sd.posW + tls.dir * 100000.0f;
			// ls.normalS = -tls.dir;
			// direction = tls.dir;
			// sourcePDF = tls.pdf;
			
			// Update reservoir:
			float targetPDF = pixelContext.evalTargetPDF(ls.Lo, direction, sg);
			
			bool updated = r.update(ls, targetPDF / sourcePDF, sg);
			
			if(updated) 
			{
				r.W = targetPDF;
			}
		}
		
		
		// Test visibility by tracing a shadow ray.
		bool V = traceShadowRay(rayOrigin, normalize(r.y.pointS - rayOrigin), distance(rayOrigin, r.y.pointS) - kShadowRayEpsilon);
		if (!V) {
			r.W = 0.0f;
			return r;
		}
		
		r.W = r.W > 0.f ? (r.wSum / r.M) / r.W : 0.f;	
		
	}
	return r;
}

/** Payload for shadow ray.
*/
struct ShadowRayData
{
    bool visible;
};

/** Traces a shadow ray towards a light source.
    \param[in] origin Ray origin for the shadow ray.
    \param[in] dir Direction from shading point towards the light source (normalized).
    \param[in] distance Distance to the light source.
    \return True if light is visible, false otherwise.
*/
bool traceShadowRay(float3 origin, float3 dir, float distance)
{
    RayDesc ray;
    ray.Origin = origin;
    ray.Direction = dir;
    ray.TMin = 0.0f;
    ray.TMax = distance;

    ShadowRayData rayData;
    rayData.visible = false;    // Set to true by miss shader if ray is not terminated before
    TraceRay(gScene.rtAccel, RAY_FLAG_ACCEPT_FIRST_HIT_AND_END_SEARCH, 0xff /* instanceInclusionMask */, 0 /* hitIdx */, rayTypeCount, 0 /* missIdx */, ray, rayData);

    return rayData.visible;
}

//
// Shader entry points for miss shaders.
//

[shader("miss")]
void shadowMiss(inout ShadowRayData rayData)
{
    // The miss shader is executed if the ray misses all geometry. Mark as visible.
    rayData.visible = true;
}

//
// Shader entry point for ray generation shader.
//

[shader("raygeneration")]
void rayGen()
{

    uint2 pixel = DispatchRaysIndex().xy;
    uint2 frameDim = DispatchRaysDimensions().xy;
	
	// ReSTIR algorithm
	Reservoir r = RIS(pixel, frameDim);
	
	gReservoirs[getBufferIndex(pixel, frameDim)] = r.pack();
	// gDebug[pixel] = float4(float3(r.W), 1);
}
