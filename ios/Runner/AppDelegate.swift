import Accelerate
import Flutter
import UIKit
import Vision

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "DeviceStoragePlugin") {
      DeviceStoragePlugin.register(with: registrar)
    }
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PersonSegmentationPlugin") {
      PersonSegmentationPlugin.register(with: registrar)
    }
  }
}

/// iOS side of the `app/device_storage` channel (see
/// lib/core/storage/device_storage.dart). Reports the capacity available for
/// "important" writes, which is what iOS will actually let the app use.
final class DeviceStoragePlugin: NSObject, FlutterPlugin {
  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "app/device_storage", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(DeviceStoragePlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    if call.method == "getTotalMemory" {
      result(NSNumber(value: ProcessInfo.processInfo.physicalMemory))
      return
    }
    guard call.method == "getFreeBytes" else {
      result(FlutterMethodNotImplemented)
      return
    }
    do {
      let home = URL(fileURLWithPath: NSHomeDirectory())
      let values = try home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
      if let bytes = values.volumeAvailableCapacityForImportantUsage {
        result(NSNumber(value: bytes))
      } else {
        result(nil)
      }
    } catch {
      result(FlutterError(code: "UNAVAILABLE", message: error.localizedDescription, details: nil))
    }
  }
}

/// iOS side of the `app/person_segmentation` channel (see
/// lib/services/ai/person_segmenter.dart). Uses Apple Vision's on-device
/// person segmentation (iOS 15+): no model download, no network.
///
/// Reads each frame file, segments it, scales the mask to the requested size
/// and appends it (8-bit, 255 = person) to the output file, so image data
/// never crosses the platform channel.
final class PersonSegmentationPlugin: NSObject, FlutterPlugin {
  private let queue = DispatchQueue(label: "person-segmentation", qos: .userInitiated)

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: "app/person_segmentation", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(PersonSegmentationPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "segmentFrames",
      let args = call.arguments as? [String: Any],
      let paths = args["framePaths"] as? [String],
      let width = args["maskWidth"] as? Int,
      let height = args["maskHeight"] as? Int,
      let output = args["outputPath"] as? String
    else {
      result(FlutterMethodNotImplemented)
      return
    }
    let append = (args["append"] as? Bool) ?? false
    #if targetEnvironment(simulator)
      // Vision's person segmentation needs the device's ML runtime, which
      // the iOS Simulator doesn't provide (fails with "E5RT is not supported").
      result(FlutterError(code: "UNSUPPORTED_DEVICE", message: "Not available in the Simulator", details: nil))
      return
    #endif
    queue.async {
      do {
        let url = URL(fileURLWithPath: output)
        if !append || !FileManager.default.fileExists(atPath: output) {
          FileManager.default.createFile(atPath: output, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        for path in paths {
          let mask = try autoreleasepool { try Self.segment(path: path, width: width, height: height) }
          try handle.write(contentsOf: mask)
        }
        DispatchQueue.main.async { result(paths.count) }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(code: "SEGMENTATION_FAILED", message: error.localizedDescription, details: nil))
        }
      }
    }
  }

  private enum SegmentationError: Error { case unreadableImage, noResult, scaleFailed }

  private static func segment(path: String, width: Int, height: Int) throws -> Data {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw SegmentationError.unreadableImage }

    let request = VNGeneratePersonSegmentationRequest()
    request.qualityLevel = .balanced
    request.outputPixelFormat = kCVPixelFormatType_OneComponent8
    try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
    guard let buffer = request.results?.first?.pixelBuffer else { throw SegmentationError.noResult }

    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw SegmentationError.noResult }
    var src = vImage_Buffer(
      data: base,
      height: vImagePixelCount(CVPixelBufferGetHeight(buffer)),
      width: vImagePixelCount(CVPixelBufferGetWidth(buffer)),
      rowBytes: CVPixelBufferGetBytesPerRow(buffer))

    var out = Data(count: width * height)
    let error = out.withUnsafeMutableBytes { raw -> vImage_Error in
      var dst = vImage_Buffer(
        data: raw.baseAddress, height: vImagePixelCount(height),
        width: vImagePixelCount(width), rowBytes: width)
      return vImageScale_Planar8(&src, &dst, nil, vImage_Flags(kvImageHighQualityResampling))
    }
    if error != kvImageNoError { throw SegmentationError.scaleFailed }
    return out
  }
}
