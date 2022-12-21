# Load render graph
m.script('..\\..\\..\\..\\Source\\Mogwai\\Data\\ReSTIR.py')

# Load scene
m.loadScene('..\\..\\..\\..\\media\\TestScenes\\Bistro_v5_2\\Bistro_v5_2\\BistroInterior_Wine.pyscene', buildFlags=SceneBuilderFlags.Default)

# Disable animations
m.scene.animated = False

# Set camera view
m.scene.camera.position = float3(2.877915,3.764648,-10.585133)
m.scene.camera.target = float3(3.449303,3.594416,-9.782302)
m.scene.camera.up = float3(0.000563,1.000000,0.000789)

# Frame capture
m.clock.exitFrame = 301
m.frameCapture.outputDir = "..\\..\\..\\..\\Source\\Mogwai\\Data\\measurements\\captured_frames\\BistroInterior"
m.frameCapture.baseFilename = "BistroInterior_"
m.frameCapture.addFrames(m.activeGraph, [100, 200, 300])