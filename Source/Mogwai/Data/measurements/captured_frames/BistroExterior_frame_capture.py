# Load render graph
m.script('..\\..\\..\\..\\Source\\Mogwai\\Data\\ReSTIR_10exp.py')

# Load scene
m.loadScene('..\\..\\..\\..\\media\\TestScenes\\Bistro_v5_2\\Bistro_v5_2\\BistroExterior.pyscene', buildFlags=SceneBuilderFlags.Default)

# Disable animations
m.scene.animated = False

# Set camera view
m.scene.camera.position = float3(-25.820202, 5.001812, -3.217541)
m.scene.camera.target = float3(-24.841011, 4.900712, -3.041578)
m.scene.camera.up = float3(0.0, 1.0, 0.0)

# Frame capture
m.clock.exitFrame = 301
m.frameCapture.outputDir = "..\\..\\..\\..\\Source\\Mogwai\\Data\\measurements\\captured_frames\\BistroExterior"
m.frameCapture.baseFilename = "BistroExterior_View1"
m.frameCapture.addFrames(m.activeGraph, [100, 200, 300])