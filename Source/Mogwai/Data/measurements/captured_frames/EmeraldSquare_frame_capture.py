# Load render graph
m.script('..\\..\\..\\..\\Source\\Mogwai\\Data\\ReSTIR_10exp.py')

# Load scene
m.loadScene('..\\..\\..\\..\\media\\TestScenes\\EmeraldSquare_v4_1\\EmeraldSquare_v4_1\\EmeraldSquare_Day.pyscene', buildFlags=SceneBuilderFlags.Default)

# Disable animations
m.scene.animated = False

# Set camera view
m.scene.camera.position = float3(4.831032,3.863522,39.884045)
m.scene.camera.target = float3(4.341336,3.767960,39.017403)
m.scene.camera.up = float3(0.000481,1.000000,0.000852)

# Disable env map
m.scene.envMap.intensity = 0

# Frame capture
m.clock.exitFrame = 301
m.frameCapture.outputDir = "..\\..\\..\\..\\Source\\Mogwai\\Data\\measurements\\captured_frames\\EmeraldSquare"
m.frameCapture.baseFilename = "EmeraldSquare"
m.frameCapture.addFrames(m.activeGraph, [100, 200, 300])