import AVFoundation
import SwiftUI
import UIKit

/// SwiftUI wrapper around AVCaptureVideoPreviewLayer. SwiftUI is not great
/// at hosting an AVFoundation layer directly, so we embed it in a UIView.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.videoPreviewLayer.session = session
        v.videoPreviewLayer.videoGravity = .resizeAspectFill
        // The capture connection stays landscape (see CameraManager). Ask
        // the preview's own connection to rotate to portrait so the user
        // sees an upright image. Inference still runs on the landscape
        // CVPixelBuffer underneath.
        if let conn = v.videoPreviewLayer.connection,
           conn.isVideoRotationAngleSupported(90) {
            conn.videoRotationAngle = 90
        }
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        // Nothing to update — session is bound once.
    }
}

/// UIView whose backing layer is AVCaptureVideoPreviewLayer so the preview
/// automatically resizes with the view.
final class PreviewView: UIView {
    override class var layerClass: AnyClass {
        AVCaptureVideoPreviewLayer.self
    }
    var videoPreviewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}
