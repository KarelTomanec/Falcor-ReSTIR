# Load render graph
m.script('..\\..\\..\\..\\Source\\Mogwai\\Data\\ReSTIR.py')

# Load scene
m.loadScene('..\\..\\..\\..\\media\\TestScenes\\CornellBox.pyscene', buildFlags=SceneBuilderFlags.Default)

# Frame capture
m.clock.exitFrame = 301
m.frameCapture.outputDir = "..\\..\\..\\..\\Source\\Mogwai\\Data\\measurements\\captured_frames\\CornellBox"
m.frameCapture.baseFilename = "CornellBox"
m.frameCapture.addFrames(m.activeGraph, [100, 200, 300])