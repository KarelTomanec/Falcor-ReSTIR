# Load render graph
m.script('..\\..\\..\\..\\Source\\Mogwai\\Data\\ReSTIR_7exp.py')

# Load scene
m.loadScene('..\\..\\..\\..\\media\\TestScenes\\ZeroDay_v1\\MEASURE_SEVEN\\MEASURE_SEVEN_COLORED_LIGHTS.fbx', buildFlags=SceneBuilderFlags.Default)

# Disable animations
m.scene.animated = False

# Set camera view
m.scene.camera.position = float3(10.653954,-0.395903,0.561934)
m.scene.camera.target = float3(10.644353,-0.397078,0.559394)
m.scene.camera.up = float3(-0.000629,0.009750,-0.002131)

# Frame capture
m.clock.exitFrame = 301
m.frameCapture.outputDir = "..\\..\\..\\..\\Source\\Mogwai\\Data\\measurements\\captured_frames\\ZeroDayColored"
m.frameCapture.baseFilename = "ZeroDayColored_"
m.frameCapture.addFrames(m.activeGraph, [100, 200, 300])