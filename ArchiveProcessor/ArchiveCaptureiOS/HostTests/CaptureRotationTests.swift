import Foundation
import CoreGraphics

// Host tests for the angle the iPhone's camera sets on each shot (W40.fix-ios-landscape-orientation), compiled with
// swiftc against the app's real Camera/CaptureRotation.swift (scripts/test-ios-capture-rotation.sh). The
// RotationCoordinator itself needs a device; these pin what the controller does with the angle it reports.

var failures = 0, passes = 0
func check(_ ok: Bool, _ what: String, line: Int = #line) {
    if ok { passes += 1 } else { failures += 1; print("  [FAIL] line \(line): \(what)") }
}
func test(_ name: String, _ body: () -> Void) {
    let before = failures
    body()
    print(failures == before ? "  [PASS] \(name)" : "  [FAIL] \(name)")
}

test("the four quarter turns pass through unchanged") {
    for a: CGFloat in [0, 90, 180, 270] { check(CaptureRotation.snapped(a) == a, "\(a)") }
}

test("off-quarter and out-of-range angles snap into [0, 360)") {
    check(CaptureRotation.snapped(89.6) == 90, "89.6")
    check(CaptureRotation.snapped(360) == 0, "360")
    check(CaptureRotation.snapped(-90) == 270, "-90")
    check(CaptureRotation.snapped(450) == 90, "450")
    check(CaptureRotation.snapped(-0.0) == 0, "-0")
    check(CaptureRotation.snapped(.nan) == 90, "nan falls back to portrait")
}

// Task 6 of iphone-1: the two ways of holding the phone sideways must differ by a half turn, so the shot that
// was filed upside down now carries EXIF 3 and the Mac turns it upright.
test("each hold maps to the EXIF orientation that turns the sensor's pixels upright") {
    check(CaptureRotation.exifOrientation(forAngle: 90) == 6, "portrait → 6")
    check(CaptureRotation.exifOrientation(forAngle: 0) == 1, "sideways, top left → 1")
    check(CaptureRotation.exifOrientation(forAngle: 180) == 3, "sideways, top right → 3")
    check(CaptureRotation.exifOrientation(forAngle: 270) == 8, "upside down → 8")
}

print("\(passes) checks passed, \(failures) failed")
exit(failures == 0 ? 0 : 1)
