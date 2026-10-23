import Accelerate
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns a camera `CVPixelBuffer` into the `Data` buffer YOLO26n expects:
/// a 1×640×640×3 float32 tensor with RGB values in [0, 1] and the source
/// image letterboxed (aspect-preserving scale + gray padding).
///
/// The `LetterboxInfo` returned lets `Yolo26PostProcessor` invert the
/// transform so bounding boxes land in the original frame's pixel space.
///
/// Sanity-check on 2026-04-22 confirmed INT8 also takes float32 input
///, so there is no per-precision branching here.
///
/// Performance: the first iOS 26 / iPhone 11 run
/// measured preprocess at 352 ms — 2× the inference itself. Two hotspots
/// were fixed:
///   1. Previous code rasterized the composited CIImage twice: once via
///      `ciContext.createCGImage(...)` and again via a second `CGContext`
///      that copied the CGImage into an `rgba` byte buffer. This is now
///      a single `ciContext.render(ci, toBitmap:rowBytes:...)` call that
///      writes straight into our buffer.
///   2. A Swift for-loop converted 1.2M uint8 bytes into Float32 RGB and
///      burned tens of ms on array bounds checks + ARC. Replaced with
///      vImage's `vImageConvert_ARGB8888toRGB888` (alpha strip) followed
///      by `vImageConvert_Planar8toPlanarF` (uint8 → float with built-in
///      per-element scale), both SIMD-accelerated.
/// Together these bring preprocess down to the sub-50 ms range.
enum Preprocessor {

    // Use sRGB explicitly for both the CIContext and the CGContext below.
    // The default CIContext on iOS often does a linearize-then-gamma pass
    // that silently darkens the output when workingColorSpace is not the
    // same as the output colorspace. Pinning both to sRGB keeps the tone
    // identical to what the user sees in the preview.
    nonisolated private static let srgb: CGColorSpace =
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    nonisolated private static let ciContext = CIContext(options: [
        .workingColorSpace: srgb,
        .outputColorSpace:  srgb,
    ])

    /// When true, the *next* call to `prepare(...)` dumps its letterbox
    /// output to Documents + fires `debugCGImageSink` + logs the luma
    /// grid, then resets this flag back to false. The user triggers this
    /// explicitly via the "Capture debug frame" button in LiveView.
    ///
    /// Note: we initially auto-dumped the first prepared frame,
    /// but that captured images before the camera's auto-exposure had
    /// converged, producing dark samples that were easily mistaken for a
    /// color-pipeline bug. Manual triggering lets the user wait ~2-3 s for
    /// AE/AWB to settle before sampling.
    nonisolated(unsafe) static var debugDumpPending: Bool = false

    /// Request a debug dump of the next prepared frame.
    nonisolated static func captureNextFrame() { debugDumpPending = true }

    /// Optional callback invoked with the debug letterboxed CGImage so the
    /// UI can show it in an in-app debug sheet (bypassing Files app).
    nonisolated(unsafe) static var debugCGImageSink: ((CGImage) -> Void)? = nil

    /// Build the input tensor + remember how the letterbox transform maps
    /// back to the camera frame.
    nonisolated static func prepare(pixelBuffer: CVPixelBuffer,
                                    spec: ModelSpec) throws -> (Data, LetterboxInfo) {

        let origW = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let origH = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let target = CGFloat(spec.inputSize)

        let scale = min(target / origW, target / origH)
        let newW  = origW * scale
        let newH  = origH * scale
        let padX  = (target - newW) / 2
        let padY  = (target - newH) / 2

        // 1) Source CIImage (BGRA from AVCaptureVideoDataOutput).
        //    Tag the incoming buffer with sRGB explicitly — otherwise
        //    CIImage assumes it's already in a linear space and CIContext's
        //    downstream sRGB encoding applies gamma twice, which is what
        //    produced the dark-looking preprocessor dump on iPhone 11.
        let ci = CIImage(
            cvPixelBuffer: pixelBuffer,
            options: [.colorSpace: Self.srgb]
        )

        // 2) Compose the letterbox image. Start from a 640×640 gray(114)
        //    canvas and overlay the scaled source at (padX, padY).
        let padGray = CGFloat(114) / 255
        // Build the gray padding in the same sRGB space as the source image
        // so the composite does not fall into a mismatched color pipeline.
        let bgColor = CIColor(red: padGray, green: padGray, blue: padGray,
                              alpha: 1.0, colorSpace: Self.srgb) ??
                      CIColor(red: padGray, green: padGray, blue: padGray)
        let bg = CIImage(color: bgColor)
            .cropped(to: CGRect(x: 0, y: 0, width: target, height: target))

        let scaled = ci
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: padX, y: padY))

        let composited = scaled
            .composited(over: bg)
            .cropped(to: CGRect(x: 0, y: 0, width: target, height: target))

        // 3) Render the composited CIImage *directly* into an RGBA8 byte
        //    buffer — no intermediate CGImage, no second CGContext. The
        //    previous two-step rasterize accounted for ~100-150 ms of the
        //    352 ms first-frame preprocess cost.
        let size = spec.inputSize
        let bytesPerPixel = 4
        let bytesPerRow   = size * bytesPerPixel
        var rgba = [UInt8](repeating: 0, count: size * size * bytesPerPixel)
        let rect = CGRect(x: 0, y: 0, width: target, height: target)
        rgba.withUnsafeMutableBytes { buf in
            guard let base = buf.baseAddress else { return }
            ciContext.render(composited,
                             toBitmap: base,
                             rowBytes: bytesPerRow,
                             bounds: rect,
                             format: .RGBA8,
                             colorSpace: Self.srgb)
        }

        // Debug: dump the letterbox image on user request. We materialize
        // a CGImage just for this path so the hot path above stays at one
        // rasterize.
        if debugDumpPending {
            debugDumpPending = false
            if let cg = ciContext.createCGImage(composited,
                                                from: rect,
                                                format: .RGBA8,
                                                colorSpace: Self.srgb) {
                dumpCGImage(cg, name: "preprocessor_input.png")
                debugCGImageSink?(cg)
            }
        }

        // 4) RGBA8 → packed Float32 RGB in [0, 1] via Accelerate/vImage.
        //    Steps:
        //      (a) Convert ARGB8888 → RGB888 (drop alpha, in place).
        //          vImage's ARGB-family helpers don't care about the
        //          specific channel order as long as we pick the right
        //          permutation — for RGBA input with alpha last, the
        //          "ARGB" name refers to the layout the routine produces,
        //          so we use `vImageConvert_RGBA8888toRGB888` (iOS 14+).
        //      (b) Convert Planar8 → PlanarF, scaling each byte by 1/255
        //          in one SIMD pass. For packed RGB that's valid because
        //          we're just reinterpreting the (size*size*3) byte block
        //          as a single "planar" channel of length 3*size*size —
        //          the result is identical to per-pixel normalization
        //          (vImageConvert_Planar8toPlanarF computes
        //          `maxFloat * (byte / 255) + minFloat * (1 - byte/255)`,
        //          so setting maxFloat=1, minFloat=0 gives byte/255).
        let pixelCount = size * size
        let rgbByteCount = pixelCount * 3
        var rgb = [UInt8](repeating: 0, count: rgbByteCount)

        var srcBuf = vImage_Buffer(
            data:     nil,
            height:   vImagePixelCount(size),
            width:    vImagePixelCount(size),
            rowBytes: bytesPerRow
        )
        var dstRGBBuf = vImage_Buffer(
            data:     nil,
            height:   vImagePixelCount(size),
            width:    vImagePixelCount(size),
            rowBytes: size * 3
        )
        let rgbaErr: vImage_Error = rgba.withUnsafeMutableBufferPointer { rgbaPtr in
            rgb.withUnsafeMutableBufferPointer { rgbPtr in
                // vImage_Buffer.data is UnsafeMutableRawPointer?; the
                // buffer pointer's baseAddress is a typed pointer and
                // Swift 6 no longer implicit-converts, so we cast.
                srcBuf.data    = UnsafeMutableRawPointer(rgbaPtr.baseAddress)
                dstRGBBuf.data = UnsafeMutableRawPointer(rgbPtr.baseAddress)
                return vImageConvert_RGBA8888toRGB888(&srcBuf, &dstRGBBuf,
                                                      vImage_Flags(kvImageNoFlags))
            }
        }
        guard rgbaErr == kvImageNoError else {
            throw DetectionError.preprocessFailed
        }

        var floats = [Float](repeating: 0, count: rgbByteCount)
        // Treat the RGB byte block as a single Planar8 channel of length
        // rgbByteCount so vImage scales each byte into [0, 1] in one call.
        let planarErr: vImage_Error = rgb.withUnsafeMutableBufferPointer { rgbPtr in
            floats.withUnsafeMutableBufferPointer { fPtr in
                var planar8 = vImage_Buffer(
                    data:     UnsafeMutableRawPointer(rgbPtr.baseAddress),
                    height:   1,
                    width:    vImagePixelCount(rgbByteCount),
                    rowBytes: rgbByteCount
                )
                var planarF = vImage_Buffer(
                    data:     UnsafeMutableRawPointer(fPtr.baseAddress),
                    height:   1,
                    width:    vImagePixelCount(rgbByteCount),
                    rowBytes: rgbByteCount * MemoryLayout<Float>.stride
                )
                return vImageConvert_Planar8toPlanarF(&planar8, &planarF,
                                                      1.0, 0.0,
                                                      vImage_Flags(kvImageNoFlags))
            }
        }
        guard planarErr == kvImageNoError else {
            throw DetectionError.preprocessFailed
        }

        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }

        let lb = LetterboxInfo(scale: scale,
                               padX:  padX,
                               padY:  padY,
                               origW: origW,
                               origH: origH)
        return (data, lb)
    }

    nonisolated private static func dumpCGImage(_ cg: CGImage, name: String) {
        // Write to Documents (for Files app viewing when UIFileSharingEnabled
        // is on) AND simultaneously emit a compact base64 summary to the
        // console so we can eyeball the pixel at well-known offsets without
        // needing to transfer the file off the device.
        let dir = FileManager.default.urls(for: .documentDirectory,
                                           in: .userDomainMask)[0]
        let url = dir.appendingPathComponent(name)
        let cfType = UTType.png.identifier as CFString
        if let dest = CGImageDestinationCreateWithURL(url as CFURL, cfType, 1, nil) {
            CGImageDestinationAddImage(dest, cg, nil)
            if CGImageDestinationFinalize(dest) {
                print("[Preprocessor] dumped \(url.path)")
            }
        }

        // In-memory PNG → base64 (first 200 chars) for quick sanity.
        let mem = NSMutableData()
        if let memDest = CGImageDestinationCreateWithData(
                mem as CFMutableData, cfType, 1, nil) {
            CGImageDestinationAddImage(memDest, cg, nil)
            if CGImageDestinationFinalize(memDest) {
                let b64 = (mem as Data).base64EncodedString()
                print("[Preprocessor] png size=\(mem.length) bytes, "
                    + "b64 first 80 chars: \(String(b64.prefix(80)))")
                // Also print a crude 8×8 grid of luminance values so we can
                // tell at a glance if the image is upright, flipped, or
                // entirely gray padding.
                let grid = sampleGrid(cg, n: 8)
                print("[Preprocessor] 8x8 luma grid (0-255):")
                for row in grid {
                    print("  " + row.map { String(format: "%3d", $0) }
                                   .joined(separator: " "))
                }
            }
        }
    }

    /// Build an n×n luminance grid sampled uniformly from `cg`. Helps
    /// eyeball orientation: a correctly letterboxed landscape photo has
    /// gray (≈114) on the top+bottom rows and varied values in the middle.
    nonisolated private static func sampleGrid(_ cg: CGImage, n: Int) -> [[Int]] {
        let w = cg.width, h = cg.height
        let bpp = 4, bpr = w * bpp
        var bytes = [UInt8](repeating: 0, count: w * h * bpp)
        let cs = CGColorSpaceCreateDeviceRGB()
        let bi = CGImageAlphaInfo.noneSkipLast.rawValue
              | CGBitmapInfo.byteOrder32Big.rawValue
        guard let ctx = CGContext(data: &bytes, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: bpr,
                                  space: cs, bitmapInfo: bi) else { return [] }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var rows: [[Int]] = []
        for gy in 0..<n {
            var row: [Int] = []
            let py = (h * gy) / n + h / (2 * n)
            for gx in 0..<n {
                let px = (w * gx) / n + w / (2 * n)
                let i = py * bpr + px * bpp
                let r = Int(bytes[i]), g = Int(bytes[i+1]), b = Int(bytes[i+2])
                // ITU-R BT.601 luma
                row.append((r * 299 + g * 587 + b * 114) / 1000)
            }
            rows.append(row)
        }
        return rows
    }
}
