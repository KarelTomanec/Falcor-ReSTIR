# Load render graph
m.script('..\\..\\..\\..\\Source\\Mogwai\\Data\\ReSTIR_TEST.py')

# Load scene
# m.loadScene('..\\..\\..\\..\\media\\TestScenes\\Arcade.pyscene', buildFlags=SceneBuilderFlags.Default)
m.loadScene('..\\..\\..\\..\\media\\TestScenes\\Bistro_v5_2\\Bistro_v5_2\\BistroExteriorView1.pyscene', buildFlags=SceneBuilderFlags.Default)

# Disable animations
# m.scene.animated = False

# Timing Capture
# m.timingCapture.captureFrameTime("..\\..\\..\\..\\Source\\Mogwai\\Data\\measurements\\captured_times\\timecapture.csv")

# Frame capture
# m.clock.exitFrame = 101
# m.frameCapture.outputDir = "..\\..\\..\\..\\Source\\Mogwai\\Data\\measurements\\captured_frames"
# m.frameCapture.baseFilename = "test_frame"
# m.frameCapture.addFrames(m.activeGraph, [20, 50, 100])


# m.clock.pause()
# m.frameCapture.outputDir = "..\\..\\..\\..\\Source\\Mogwai\\Data\\measurements\\captured_frames"
# while True:
    # renderFrame()
    # if 83.5 <= m.clock.time <= 84.0:
        # m.frameCapture.baseFilename = f"MogwaiT-{int(m.clock.time):04d}"
        # m.frameCapture.capture()
# exit()

# Video Capture
# m.videoCapture.outputDir = "..\\..\\..\\..\\Source\\Mogwai\\Data\\measurements\\captured_videos"
# m.videoCapture.baseFilename = "test_video"
# m.videoCapture.codec = Codec.H264
# m.videoCapture.fps = 60
# m.videoCapture.bitrate = 4.0
# m.videoCapture.gopSize = 10
# m.videoCapture.addRanges(m.activeGraph, [[30, 300]])

# Profiling
m.profiler.enabled = True
m.profiler.startCapture()
for frame in range(256):
    m.renderFrame()
capture = m.profiler.endCapture()
m.profiler.enabled = False
meanFrameTime = capture["events"]["/onFrameRender/gpuTime"]["stats"]["mean"]
print("Mean frame time: {}", meanFrameTime)