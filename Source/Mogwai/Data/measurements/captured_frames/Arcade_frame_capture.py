# Load render graph
m.script('..\\..\\..\\..\\Source\\Mogwai\\Data\\ReSTIR.py')

# Load scene
m.loadScene('..\\..\\..\\..\\media\\Arcade\\Arcade.pyscene', buildFlags=SceneBuilderFlags.Default)

# Frame capture
m.clock.exitFrame = 301
m.frameCapture.outputDir = "..\\..\\..\\..\\Source\\Mogwai\\Data\\measurements\\captured_frames\\Arcade"
m.frameCapture.baseFilename = "Arcade"
m.frameCapture.addFrames(m.activeGraph, [100, 200, 300])