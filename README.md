<p align="center">
  <img src="YOLOkemon/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="160" alt="YOLOkémon app icon">
</p>

<h1 align="center">YOLOkémon</h1>

<p align="center">
  Real-time on-device object detection for iOS, turned into a Pokémon-style "catch 'em all" game.
</p>

---

YOLOkémon runs a YOLO26n detector through TensorFlow Lite directly on the iPhone camera feed.
Point the camera at everyday objects, pick one by voice, hold steady, and catch it into your
Pokédex of all 80 COCO classes. Under the hood it doubles as a benchmarking tool: switch
between FP32, FP16 and INT8 models at runtime and compare latency, FPS, memory, thermal state
and battery drain live.

## Features

- **Live detection**: camera preview with bounding boxes and class labels, fully on-device
  (TFLite + XNNPACK on CPU, 640×640 input).
- **Runtime precision switching**: swap between `FP32`, `FP16` and `INT8` builds of YOLO26n
  without restarting the camera.
- **Voice commands** (`SFSpeechRecognizer`, en-US, push-to-talk with silence detection):
  - `"find the cup"`, `"show the laptop"`: highlight a target class
  - `"I choose the cup"`, `"catch cup"`: start a capture
  - `"give up"`, `"stop"`: cancel the capture
  - `"open pokedex"`: jump to the Pokédex tab
- **Capture mechanic**: capture progress grows while the target's bounding box stays stable
  between frames (IoU > 0.85 full gain, > 0.60 partial gain, otherwise decay). A still target
  is caught in about 2.5 s at 30 fps; near-misses play a "Got away!" animation.
- **Pokédex**: persistent catalog of all 80 COCO classes. Caught entries record time-to-catch,
  attempt count, and a badge for every precision that has caught them.
- **Dashboard**: per-precision latency breakdown (preprocess / inference / postprocess), FPS,
  model size, capture stability stats, plus thermal state, memory usage and battery drain.
- **Export**: dump the session log to CSV or JSON in `Documents/yolokemon_logs/`, accessible
  from the iOS Files app.

## Requirements

- Xcode 26 or later
- iOS 26.4 or later
- A physical iPhone (the simulator has no camera). Developed and tested on an iPhone 11.

## Getting started

```bash
git clone https://github.com/jiseungjeong/YOLOkemon.git
cd YOLOkemon
open YOLOkemon.xcodeproj
```

1. Select the `YOLOkemon` target, open **Signing & Capabilities**, and choose your own
   development team (change the bundle identifier if needed).
2. Connect an iPhone and press **Run**.
3. Grant camera, microphone and speech recognition permissions when prompted.

No package manager setup is required: the TensorFlow Lite C framework and the three
`.tflite` models are checked into the repository.

## Project structure

```
YOLOkemon/
├── App/            App entry point and tab container
├── Camera/         AVCaptureSession management and preview layer
├── Detection/      Preprocessing, TFLite inference, YOLO26 postprocessing, capture engine
├── Data/           Pokédex entries and persistent store
├── Target/         Currently selected voice target
├── Voice/          Speech recognition and command parsing
├── Logging/        Per-frame session log and CSV/JSON export
├── Metrics/        Memory, battery and thermal readings
├── Views/          SwiftUI screens (Live, Dashboard, Pokédex, Export) and components
├── TFLiteSwift/    Vendored TensorFlow Lite Swift API
├── Frameworks/     TensorFlowLiteC.xcframework
└── Assets/         yolo26n_{fp32,fp16,int8}.tflite and COCO labels
```

### Inference pipeline

1. `CameraManager` delivers portrait `CVPixelBuffer` frames on a dedicated queue.
2. `Preprocessor` letterboxes each frame to 640×640 RGB float32 using vImage.
3. `DetectionEngine` runs the selected TFLite interpreter (XNNPACK, 4 threads).
4. `Yolo26PostProcessor` thresholds the NMS-free `[1, 300, 6]` output, filters duplicate
   boxes, and maps boxes back to source pixel coordinates.
5. `LiveView` draws the overlay, feeds detections to `CaptureEngine`, and appends a
   `LogRecord` to the shared `SessionLogStore`.

Metal and Core ML delegates were evaluated but only support a small fraction of YOLO26n's
ops, so inference is fixed to CPU and precision is the single runtime knob.

## Acknowledgements

- [Ultralytics YOLO26](https://github.com/ultralytics/ultralytics) for the detection model
  (AGPL-3.0).
- [TensorFlow Lite](https://github.com/tensorflow/tensorflow) for the runtime and Swift API
  (Apache-2.0).
- Pokémon and Poké Ball are trademarks of Nintendo / Creatures Inc. / GAME FREAK inc. This is an
  unofficial fan project with no affiliation.

## License

This project is licensed under the [GNU Affero General Public License v3.0](LICENSE), matching
the license of the bundled Ultralytics YOLO26 models. The vendored TensorFlow Lite sources and
framework remain under the Apache License 2.0.
