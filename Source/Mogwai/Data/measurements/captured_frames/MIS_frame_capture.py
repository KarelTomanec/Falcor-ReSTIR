# Load render graph
m.script('..\\..\\..\\..\\Source\\Mogwai\\Data\\ReSTIR.py')

# Load scene
m.loadScene('..\\..\\..\\..\\media\\TestScenes\\veach-mis\\veach-mis\\scene-v4.pbrt', buildFlags=SceneBuilderFlags.Default)

# Frame capture
m.clock.exitFrame = 301
m.frameCapture.outputDir = "..\\..\\..\\..\\Source\\Mogwai\\Data\\measurements\\captured_frames\\MIS"
m.frameCapture.baseFilename = "MIS"
m.frameCapture.addFrames(m.activeGraph, [100, 200, 300])