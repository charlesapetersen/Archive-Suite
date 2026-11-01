import Foundation
import CoreGraphics

/// The rotation a shot is taken with, so a page photographed with the phone held sideways arrives upright
/// (W40.fix-ios-landscape-orientation). The UI is portrait-only, so the interface orientation says nothing about
/// how the phone is held; `CameraController` reads the device's real orientation from an
/// `AVCaptureDevice.RotationCoordinator` and sets the snapped angle on the photo connection. AVCapturePhotoOutput then
/// writes the matching EXIF orientation (it does not rotate the pixels), which the Mac applies when it reads the JPEG
/// (`kCGImageSourceCreateThumbnailWithTransform` in ImageEncoding/PDFGenerator).
///
/// Plain Foundation so the host tests compile it with swiftc (scripts/test-ios-capture-rotation.sh).
enum CaptureRotation {
    /// The coordinator's angle snapped to the nearest quarter turn in [0, 360). It reports 0, 90, 180 or 270 for the
    /// back camera, but a connection refuses an angle it does not support, so anything else is snapped rather than
    /// passed through.
    static func snapped(_ degrees: CGFloat) -> CGFloat {
        guard degrees.isFinite else { return 90 }
        let quarter = (degrees / 90).rounded()
        let angle = (quarter * 90).truncatingRemainder(dividingBy: 360)
        return angle < 0 ? angle + 360 : angle
    }

    /// The EXIF orientation a JPEG taken at `angle` carries: the clockwise rotation that turns the sensor's
    /// landscape pixels upright. 0 is the sensor's own orientation (phone held sideways, top to the left).
    static func exifOrientation(forAngle angle: CGFloat) -> Int {
        switch snapped(angle) {
        case 90: return 6   // portrait: pixels shown rotated 90° clockwise
        case 180: return 3  // sideways, top to the right
        case 270: return 8  // upside-down portrait
        default: return 1   // sideways, top to the left
        }
    }
}
