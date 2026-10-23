import SwiftUI

/// Draws bounding boxes + class labels on top of the camera preview.
///
/// Pipeline geometry:
///   - `CameraManager` sets `videoRotationAngle = 90` on the data output
///     connection, so the `CVPixelBuffer` we receive is already portrait
///     (e.g. 720×1280). `Preprocessor` runs letterbox on that portrait
///     buffer, and `Yolo26PostProcessor` returns boxes in portrait source
///     pixel coordinates.
///   - The preview layer's own connection is also rotated 90° and uses
///     `.resizeAspectFill`, so on-screen we see the same portrait image
///     filled into the view bounds with center-cropping on the long axis.
///   - This overlay therefore only needs `.resizeAspectFill` scaling — no
///     rotation step.
///
/// ## YOLOkémon additions
/// When `captureEngine.isCapturing` is true the overlay renders a
/// progress bar pinned above the active target box, plus a status chip
/// showing `Capturing cup… 72%`. The bar is rendered as a regular
/// SwiftUI view (not drawn into the `Canvas`) so we get spring
/// animations on progress changes for free.
struct LiveOverlayView: View {
    let detections: [Detection]
    /// Portrait pixel size of the source buffer (CVPixelBufferGetWidth/Height).
    let sourceSize: CGSize
    /// Label of the currently selected voice target. Target matches
    /// are drawn green, everything else orange.
    let targetLabel: String?

    /// YOLOkémon capture state. Passed in as an ObservedObject so SwiftUI
    /// redraws the bar whenever `captureProgress` ticks.
    @ObservedObject var captureEngine: CaptureEngine

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Canvas { ctx, _ in
                    let m = transform(in: geo.size)
                    for d in detections {
                        draw(ctx, detection: d, mapping: m)
                    }
                }
                .allowsHitTesting(false)

                // Capture bar sits above whichever target box is
                // currently being captured. We only render when both a
                // session is active AND the target is visible this
                // frame — if the target flickers out we drop the bar
                // rather than showing a frozen last position.
                if captureEngine.isCapturing,
                   let cls = captureEngine.targetClass,
                   let box = targetBox(for: cls, in: geo.size) {
                    captureBar(rect: box,
                               progress: captureEngine.captureProgress,
                               label: cls)
                }
            }
        }
    }

    // MARK: - Mapping

    private struct Mapping {
        let scale:   CGFloat
        let offsetX: CGFloat
        let offsetY: CGFloat
    }

    private func transform(in viewSize: CGSize) -> Mapping {
        let srcW = max(sourceSize.width,  1)
        let srcH = max(sourceSize.height, 1)
        let scale   = max(viewSize.width / srcW, viewSize.height / srcH)
        let filledW = srcW * scale
        let filledH = srcH * scale
        let offsetX = (viewSize.width  - filledW) / 2
        let offsetY = (viewSize.height - filledH) / 2
        return Mapping(scale: scale, offsetX: offsetX, offsetY: offsetY)
    }

    /// Screen-space rect of the highest-confidence detection matching
    /// `cls`, or nil if none this frame.
    private func targetBox(for cls: String, in viewSize: CGSize) -> CGRect? {
        let matches = detections.filter { $0.label == cls }
        guard let best = matches.max(by: { $0.confidence < $1.confidence }) else {
            return nil
        }
        let m = transform(in: viewSize)
        return CGRect(
            x: best.box.minX * m.scale + m.offsetX,
            y: best.box.minY * m.scale + m.offsetY,
            width:  best.box.width  * m.scale,
            height: best.box.height * m.scale
        )
    }

    // MARK: - Drawing

    private func draw(_ ctx: GraphicsContext,
                      detection d: Detection,
                      mapping m: Mapping) {
        let isTarget = (d.label == targetLabel)
        let stroke: Color = isTarget ? .green : .orange

        let rect = CGRect(
            x: d.box.minX * m.scale + m.offsetX,
            y: d.box.minY * m.scale + m.offsetY,
            width:  d.box.width  * m.scale,
            height: d.box.height * m.scale
        )

        var box = Path()
        box.addRect(rect)
        ctx.stroke(box, with: .color(stroke), lineWidth: 3)

        let text = Text("\(d.label)  \(Int((d.confidence * 100).rounded()))%")
            .font(.caption).bold()
            .foregroundColor(.white)
        let resolved = ctx.resolve(text)
        let textSize = resolved.measure(in: CGSize(width: 240, height: 40))
        let pad: CGFloat = 4
        let chipW = textSize.width  + pad * 2
        let chipH = textSize.height + pad * 2
        let chipY = rect.minY - chipH >= 0 ? rect.minY - chipH : rect.minY
        let chip = CGRect(x: rect.minX, y: chipY, width: chipW, height: chipH)
        ctx.fill(Path(chip), with: .color(stroke))
        ctx.draw(resolved,
                 at: CGPoint(x: chip.minX + pad, y: chip.minY + pad),
                 anchor: .topLeading)
    }

    // MARK: - Capture bar

    @ViewBuilder
    private func captureBar(rect: CGRect,
                            progress: Double,
                            label: String) -> some View {
        // 10-segment bar sized to the box width, placed just above the
        // green target chip. Colors step through red → yellow → green
        // so the rising "heat" reads at a glance even without the
        // percentage text below.
        let segments = 10
        let filled = min(segments, Int((progress * Double(segments)).rounded()))
        let pct = Int((progress * 100).rounded())
        let barWidth = max(rect.width, 120)
        let barHeight: CGFloat = 10

        // Anchor above the chip (chip is ~22pt tall, so lift ~38 pt).
        let y = max(rect.minY - 38, 8)
        let x = rect.minX

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                ForEach(0..<segments, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(segmentColor(index: i,
                                           filled: filled,
                                           total: segments))
                        .frame(height: barHeight)
                }
            }
            .frame(width: barWidth)

            Text("Capturing \(label)… \(pct)%")
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(PokemonColor.pokeballCenter.opacity(0.8))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .position(x: x + barWidth / 2, y: y)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.2), value: progress)
    }

    private func segmentColor(index: Int, filled: Int, total: Int) -> Color {
        guard index < filled else { return Color.white.opacity(0.25) }
        let ratio = Double(index) / Double(max(total - 1, 1))
        if ratio < 0.3 { return .red }
        if ratio < 0.7 { return PokemonColor.pokedexYellow }
        return .green
    }
}

#Preview {
    ZStack {
        Color.black
        LiveOverlayView(
            detections: [
                Detection(classId: 41, label: "cup",
                          confidence: 0.88,
                          box: CGRect(x: 200, y: 400, width: 300, height: 450)),
                Detection(classId: 73, label: "book",
                          confidence: 0.52,
                          box: CGRect(x: 80, y: 900, width: 500, height: 300)),
            ],
            sourceSize: CGSize(width: 720, height: 1280),
            targetLabel: "cup",
            captureEngine: {
                let e = CaptureEngine()
                e.startCapture(targetClass: "cup")
                return e
            }()
        )
    }
    .aspectRatio(9.0/16.0, contentMode: .fit)
}
