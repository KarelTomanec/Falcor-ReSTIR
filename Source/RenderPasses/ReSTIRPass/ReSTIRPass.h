/***************************************************************************
 # Copyright (c) 2015-21, NVIDIA CORPORATION. All rights reserved.
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
#pragma once
#include "Falcor.h"
#include "Utils/Sampling/SampleGenerator.h"
#include "Rendering/Lights/EmissivePowerSampler.h"
#include "Rendering/Lights/EnvMapSampler.h"
#include "Utils/Sampling/AliasTable.h"
#include "RenderGraph/RenderPassHelpers.h"

using namespace Falcor;

class ReSTIRPass : public RenderPass
{
public:
    using SharedPtr = std::shared_ptr<ReSTIRPass>;

    static const Info kInfo;

    /** Create a new render pass object.
        \param[in] pRenderContext The render context.
        \param[in] dict Dictionary of serialized parameters.
        \return A new object, or an exception is thrown if creation failed.
    */
    static SharedPtr create(RenderContext* pRenderContext = nullptr, const Dictionary& dict = {});

    virtual Dictionary getScriptingDictionary() override;
    virtual RenderPassReflection reflect(const CompileData& compileData) override;
    virtual void compile(RenderContext* pRenderContext, const CompileData& compileData) override {}
    virtual void execute(RenderContext* pRenderContext, const RenderData& renderData) override;
    virtual void renderUI(Gui::Widgets& widget) override;
    virtual void setScene(RenderContext* pRenderContext, const Scene::SharedPtr& pScene) override;
    virtual bool onMouseEvent(const MouseEvent& mouseEvent) override { return false; }
    virtual bool onKeyEvent(const KeyboardEvent& keyEvent) override { return false; }

    enum class Mode
    {
        NoResampling,
        SpatialResampling,
        TemporalResampling,
        SpatiotemporalResampling,
        DecoupledPipeline,
        ReSTIRGI,
    };

    enum class BiasCorrection
    {
        Off,
        Naive,
        MIS,
        RayTraced,
    };

private:

    struct TracePass
    {
        std::string name;
        std::string passDefine;
        RtProgram::SharedPtr pProgram;
        RtBindingTable::SharedPtr pBindingTable;
        RtProgramVars::SharedPtr pVars;

        TracePass(const std::string& name, const std::string& passDefine, const Scene::SharedPtr& pScene, const Program::DefineList& defines, const Program::TypeConformanceList& globalTypeConformances);
        void prepareProgram(const Program::DefineList& defines);
    };

    ReSTIRPass(const Dictionary& dict);
    void parseDictionary(const Dictionary& dict);
    void prepareMaterials(RenderContext* pRenderContext);

    bool prepareLighting(RenderContext* pRenderContext);
    void resetLighting();

    AliasTable::SharedPtr createEmissiveGeometryAliasTable(RenderContext* pRenderContext, const LightCollection::SharedPtr& lightCollection);
    AliasTable::SharedPtr createEnvironmentAliasTable(RenderContext* pRenderContext, const Texture::SharedPtr& envTexture);
    AliasTable::SharedPtr createAnalyticLightsAliasTable(RenderContext* pRenderContext);

    bool beginFrame(RenderContext* pRenderContext, const RenderData& renderData);
    void endFrame(RenderContext* pRenderContext, const RenderData& renderData);
    void setFrameDim(const uint2 frameDim);
    void updatePrograms();
    void prepareResources(RenderContext* pRenderContext, const RenderData& renderData);

    void tracePass(RenderContext* pRenderContext, const RenderData& renderData, TracePass& tracePass);
    void createLightTiles(RenderContext* pRenderContext);
    void loadSurfaceDataPass(RenderContext* pRenderContext, const RenderData& renderData);
    void generateInitialCandidatesPass(RenderContext* pRenderContext, const RenderData& renderData);
    void temporalReusePass(RenderContext* pRenderContext, const RenderData& renderData);
    void spatialReusePass(RenderContext* pRenderContext, const RenderData& renderData);
    void createDirectSamplesPass(RenderContext* pRenderContext, const RenderData& renderData);
    void shadePass(RenderContext* pRenderContext, const RenderData& renderData);
    void temporalReuseGIPass(RenderContext* pRenderContext, const RenderData& renderData);
    void spatialReuseGIPass(RenderContext* pRenderContext, const RenderData& renderData);
    void shadingIndirectPass(RenderContext* pRenderContext, const RenderData& renderData);

    void decoupledPipelinePass(RenderContext* pRenderContext, const RenderData& renderData);

    void prepareRenderPass(const RenderData& renderData);
    void setShaderData(const ShaderVar& var, const RenderData& renderData, bool useLightSampling = true) const;
    bool renderRenderingUI(Gui::Widgets& widget);

    /** Static configuration. Changing any of these options require shader recompilation.
    */
    struct StaticParams
    {
        // Sampling parameters
        uint32_t    sampleGenerator = SAMPLE_GENERATOR_TINY_UNIFORM; ///< Pseudorandom sample generator type.
        EmissiveLightSamplerType emissiveSampler = EmissiveLightSamplerType::Power;  ///< Emissive light sampler to use.

        Program::DefineList getDefines(const ReSTIRPass& owner) const;
    };

    struct ReSTIRParams
    {
        uint32_t    lightTileScreenSize = 8;
        uint32_t    lightTileSize = 1024;
        uint32_t    lightTileCount = 128;

        bool        testInitialSampleVisibility = true;
        uint32_t    emissiveLightCandidateCount = 32; // = 24
        uint32_t    envLightCandidateCount = 0; // = 8
        uint32_t    analyticLightCandidateCount = 0;

        BiasCorrection biasCorrection = BiasCorrection::Off;
        float       normalThreshold = 0.5f;
        float       depthThreshold = 0.1f;

        uint32_t    spatialIterationCount = 1;
        uint32_t    spatialReuseSampleCount = 1;
        float       spatialReuseSampleRadius = 30.f;

        uint32_t    temporalHistoryLength = 20;

        bool        useCheckerboarding = false;

        float       spatialVisibilityThreshold = 0.f;

        Mode        mode = Mode::SpatiotemporalResampling;
    };

    // Configuration
    StaticParams                    mStaticParams;              ///< Static parameters. These are set as compile-time constants in the shaders.
    bool                            mEnabled = true;            ///< Switch to enable/disable the render pass. When disabled the pass outputs are cleared.
    RenderPassHelpers::IOSize       mOutputSizeSelection = RenderPassHelpers::IOSize::Default;  ///< Selected output size.
    uint2                           mFixedOutputSize = { 512, 512 };                            ///< Output size in pixels when 'Fixed' size is selected.


    ReSTIRParams                    mReSTIRParams;

    // Internal state
    Scene::SharedPtr                mpScene;                    ///< The current scene, or nullptr if no scene loaded.
    SampleGenerator::SharedPtr      mpSampleGenerator;          ///< GPU pseudo-random sample generator.
    EnvMapSampler::SharedPtr        mpEnvMapSampler;            ///< Environment map sampler or nullptr if not used.
    EmissiveLightSampler::SharedPtr mpEmissiveSampler;          ///< Emissive light sampler or nullptr if not used.

    ComputePass::SharedPtr          mpCreateLightTiles;
    ComputePass::SharedPtr          mpLoadSurfaceDataPass;
    ComputePass::SharedPtr          mpGenerateInitialCandidatesPass;
    ComputePass::SharedPtr          mpTemporalReusePass;
    ComputePass::SharedPtr          mpSpatialReusePass;
    ComputePass::SharedPtr          mpCreateDirectLightSamplesPass;
    ComputePass::SharedPtr          mpShadePass;
    ComputePass::SharedPtr          mpShadingIndirect;
    ComputePass::SharedPtr          mpTemporalReuseGIPass;
    ComputePass::SharedPtr          mpSpatialReuseGIPass;

    ComputePass::SharedPtr          mpDecoupledPipelinePass;

    std::unique_ptr<TracePass>      mpTracePass;                ///< Main trace pass.

    // Runtime data
    uint                            mFrameCount = 0;        ///< Frame count since scene was loaded.
    uint2                           mFrameDim = uint2(0, 0);

    bool                            mOptionsChanged = false;
    bool                            mRecompile = false;         ///< Set to true when program specialization has changed.
    bool                            mVarsChanged = true;        ///< This is set to true whenever the program vars have changed and resources need to be rebound.

    // Textures and buffer
    Buffer::SharedPtr               mpReservoirs;

    Buffer::SharedPtr               mpDirectLightSamples;

    Buffer::SharedPtr               mpSurfaceData;

    Buffer::SharedPtr               mpPrevSurfaceData;
    Buffer::SharedPtr               mpPrevReservoirs;

    Buffer::SharedPtr               mpGIReservoirs;
    Buffer::SharedPtr               mpPrevGIReservoirs;

    // Emissive geometry sampling data
    AliasTable::SharedPtr mpEmissiveGeometryAliasTable;
    AliasTable::SharedPtr mpEnvironmentAliasTable;
    AliasTable::SharedPtr mpAnalyticLightsAliasTable;

    Buffer::SharedPtr mpEnvironmentLuminanceTable;

    Buffer::SharedPtr mpLightTiles;

    std::mt19937 mRnd;
};
