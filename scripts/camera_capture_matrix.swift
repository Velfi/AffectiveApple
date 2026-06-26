#!/usr/bin/env swift

import AVFoundation
import CoreImage
import Foundation
import ImageIO

struct Options {
    var outputURL = URL(fileURLWithPath: "camera-matrix-\(Self.timestamp())", isDirectory: true)
    var deviceID: String?
    var delays: [Double] = [0, 0.10, 0.20, 0.35, 0.50, 0.75, 1.00, 1.50]
    var frames: [Int] = [1, 3, 5, 8, 12, 16, 24]
    var trials = 2
    var timeoutSeconds: Double = 6
    var listDevices = false
    var help = false

    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}

struct CaptureResult {
    let data: Data
    let width: Int
    let height: Int
    let elapsedSeconds: Double
    let frameCount: Int
    let stats: ImageStats
}

struct ImageStats {
    let mean: Double
    let standardDeviation: Double
    let min: Double
    let max: Double
    let isNearlyBlack: Bool
}

enum ProbeError: Error, CustomStringConvertible {
    case noCamera
    case notAuthorized(AVAuthorizationStatus)
    case cannotConfigure
    case timeout
    case noImageData
    case invalidArguments(String)

    var description: String {
        switch self {
        case .noCamera:
            return "No camera matched the requested device."
        case .notAuthorized(let status):
            return "Camera authorization is \(status). Grant camera access and rerun."
        case .cannotConfigure:
            return "The capture session could not be configured."
        case .timeout:
            return "Timed out waiting for the requested frame."
        case .noImageData:
            return "The camera returned no image data."
        case .invalidArguments(let message):
            return message
        }
    }
}

final class MatrixCaptureSession: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "Affective.camera.matrix.probe")
    private let imageContext = CIContext()
    private let minDelay: Double
    private let minFrames: Int
    private let timeoutSeconds: Double
    private let preferredDeviceID: String?
    private var startedAt = Date()
    private var frameCount = 0
    private var isFinished = false
    private var completion: ((Result<CaptureResult, Error>) -> Void)?

    init(minDelay: Double, minFrames: Int, timeoutSeconds: Double, preferredDeviceID: String?) {
        self.minDelay = minDelay
        self.minFrames = max(minFrames, 1)
        self.timeoutSeconds = timeoutSeconds
        self.preferredDeviceID = preferredDeviceID
    }

    func capture(completion: @escaping (Result<CaptureResult, Error>) -> Void) {
        queue.async {
            self.completion = completion
            self.startedAt = Date()
            self.frameCount = 0
            self.isFinished = false
            do {
                try self.configureSession()
                self.session.startRunning()
                guard self.session.isRunning else {
                    throw ProbeError.cannotConfigure
                }
                self.queue.asyncAfter(deadline: .now() + self.timeoutSeconds) {
                    self.finish(.failure(ProbeError.timeout))
                }
            } catch {
                self.finish(.failure(error))
            }
        }
    }

    private func configureSession() throws {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        guard status == .authorized else {
            throw ProbeError.notAuthorized(status)
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .high

        guard let device = Self.preferredCameraDevice(uniqueID: preferredDeviceID) else {
            throw ProbeError.noCamera
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw ProbeError.cannotConfigure
        }
        session.addInput(input)

        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else {
            throw ProbeError.cannotConfigure
        }
        session.addOutput(output)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        frameCount += 1
        let elapsed = Date().timeIntervalSince(startedAt)
        guard frameCount >= minFrames, elapsed >= minDelay else {
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let data = imageContext.jpegRepresentation(of: image, colorSpace: colorSpace) else {
            return
        }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let stats = Self.stats(for: data, width: width, height: height) else {
            finish(.failure(ProbeError.noImageData))
            return
        }
        finish(.success(CaptureResult(
            data: data,
            width: width,
            height: height,
            elapsedSeconds: elapsed,
            frameCount: frameCount,
            stats: stats
        )))
    }

    private func finish(_ result: Result<CaptureResult, Error>) {
        queue.async {
            guard !self.isFinished else { return }
            self.isFinished = true
            self.output.setSampleBufferDelegate(nil, queue: nil)
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.completion?(result)
            self.completion = nil
        }
    }

    static func preferredCameraDevice(uniqueID: String?) -> AVCaptureDevice? {
        let devices = availableCameraDevices()
        if let uniqueID {
            return devices.first { $0.uniqueID == uniqueID }
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? devices.first
            ?? AVCaptureDevice.default(for: .video)
    }

    static func availableCameraDevices() -> [AVCaptureDevice] {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        return session.devices.sorted { lhs, rhs in
            let lhsRank = cameraDeviceAutomaticRank(lhs)
            let rhsRank = cameraDeviceAutomaticRank(rhs)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return lhs.localizedName.localizedCaseInsensitiveCompare(rhs.localizedName) == .orderedAscending
        }
    }

    private static func cameraDeviceAutomaticRank(_ device: AVCaptureDevice) -> Int {
        let name = device.localizedName.lowercased()
        if name.contains("obs") {
            return 100
        }
        if name.contains("virtual") || name.contains("screen capture") {
            return 90
        }
        if device.deviceType == .builtInWideAngleCamera {
            return 0
        }
        return 10
    }

    static func stats(for data: Data, width: Int, height: Int) -> ImageStats? {
        guard width * height >= 1 else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }

        let sampleWidth = min(width, 32)
        let sampleHeight = min(height, 32)
        let bytesPerPixel = 4
        let bytesPerRow = sampleWidth * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: sampleHeight * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

        let didDraw = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: sampleWidth,
                height: sampleHeight,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else {
                return false
            }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))
            return true
        }
        guard didDraw else { return nil }

        var sum = 0.0
        var squaredSum = 0.0
        var minValue = Double.greatestFiniteMagnitude
        var maxValue = 0.0
        let sampleCount = sampleWidth * sampleHeight
        for index in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            let red = Double(pixels[index])
            let green = Double(pixels[index + 1])
            let blue = Double(pixels[index + 2])
            let luminance = (0.2126 * red) + (0.7152 * green) + (0.0722 * blue)
            sum += luminance
            squaredSum += luminance * luminance
            minValue = min(minValue, luminance)
            maxValue = max(maxValue, luminance)
        }

        let mean = sum / Double(sampleCount)
        let variance = max((squaredSum / Double(sampleCount)) - (mean * mean), 0)
        let standardDeviation = sqrt(variance)
        return ImageStats(
            mean: mean,
            standardDeviation: standardDeviation,
            min: minValue,
            max: maxValue,
            isNearlyBlack: (mean < 8 && standardDeviation < 4) || (maxValue < 8 && mean < 4 && standardDeviation < 2)
        )
    }
}

func parseOptions() throws -> Options {
    var options = Options()
    var index = 1
    let arguments = CommandLine.arguments

    func requireValue(after flag: String) throws -> String {
        guard index + 1 < arguments.count else {
            throw ProbeError.invalidArguments("Missing value after \(flag).")
        }
        index += 1
        return arguments[index]
    }

    while index < arguments.count {
        let arg = arguments[index]
        switch arg {
        case "--help", "-h":
            options.help = true
        case "--list-devices":
            options.listDevices = true
        case "--output":
            options.outputURL = URL(fileURLWithPath: try requireValue(after: arg), isDirectory: true)
        case "--device":
            options.deviceID = try requireValue(after: arg)
        case "--delays":
            options.delays = try parseDoubles(try requireValue(after: arg), flag: arg)
        case "--frames":
            options.frames = try parseInts(try requireValue(after: arg), flag: arg)
        case "--trials":
            options.trials = try parsePositiveInt(try requireValue(after: arg), flag: arg)
        case "--timeout":
            options.timeoutSeconds = try parsePositiveDouble(try requireValue(after: arg), flag: arg)
        default:
            throw ProbeError.invalidArguments("Unknown argument: \(arg)")
        }
        index += 1
    }

    return options
}

func parseDoubles(_ value: String, flag: String) throws -> [Double] {
    let values = value.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard !values.isEmpty else {
        throw ProbeError.invalidArguments("\(flag) needs comma-separated numbers.")
    }
    return values
}

func parseInts(_ value: String, flag: String) throws -> [Int] {
    let values = value.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    guard !values.isEmpty else {
        throw ProbeError.invalidArguments("\(flag) needs comma-separated integers.")
    }
    return values
}

func parsePositiveInt(_ value: String, flag: String) throws -> Int {
    guard let parsed = Int(value), parsed > 0 else {
        throw ProbeError.invalidArguments("\(flag) must be a positive integer.")
    }
    return parsed
}

func parsePositiveDouble(_ value: String, flag: String) throws -> Double {
    guard let parsed = Double(value), parsed > 0 else {
        throw ProbeError.invalidArguments("\(flag) must be a positive number.")
    }
    return parsed
}

func printHelp() {
    print("""
    Usage:
      swift scripts/camera_capture_matrix.swift [options]

    Options:
      --output PATH       Output directory. Defaults to camera-matrix-YYYYMMDD-HHMMSS.
      --device UNIQUE_ID  Camera device unique ID. Use --list-devices to discover IDs.
      --delays LIST       Comma-separated seconds. Default: 0,0.10,0.20,0.35,0.50,0.75,1.00,1.50
      --frames LIST       Comma-separated frame counts. Default: 1,3,5,8,12,16,24
      --trials N          Trials per matrix cell. Default: 2
      --timeout SECONDS   Timeout per capture. Default: 6
      --list-devices      Print camera devices and exit.
      --help              Print this help.

    Example:
      swift scripts/camera_capture_matrix.swift --output /tmp/camera-matrix --delays 0,0.25,0.5,1.0 --frames 1,4,8,16 --trials 3
    """)
}

func printDevices() {
    let devices = MatrixCaptureSession.availableCameraDevices()
    if devices.isEmpty {
        print("No camera devices found.")
        return
    }
    for device in devices {
        print("\(device.localizedName)\t\(device.uniqueID)\t\(device.deviceType.rawValue)")
    }
}

func requestAuthorizationIfNeeded() -> Bool {
    switch AVCaptureDevice.authorizationStatus(for: .video) {
    case .authorized:
        return true
    case .notDetermined:
        let semaphore = DispatchSemaphore(value: 0)
        var granted = false
        AVCaptureDevice.requestAccess(for: .video) { value in
            granted = value
            semaphore.signal()
        }
        semaphore.wait()
        return granted
    default:
        return false
    }
}

func csvEscaped(_ value: String) -> String {
    if value.contains(",") || value.contains("\"") || value.contains("\n") {
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
    return value
}

func runCapture(minDelay: Double, minFrames: Int, timeout: Double, deviceID: String?) -> Result<CaptureResult, Error> {
    let semaphore = DispatchSemaphore(value: 0)
    var result: Result<CaptureResult, Error>!
    let capture = MatrixCaptureSession(
        minDelay: minDelay,
        minFrames: minFrames,
        timeoutSeconds: timeout,
        preferredDeviceID: deviceID
    )
    capture.capture {
        result = $0
        semaphore.signal()
    }
    semaphore.wait()
    return result
}

do {
    let options = try parseOptions()
    if options.help {
        printHelp()
        exit(0)
    }
    if options.listDevices {
        printDevices()
        exit(0)
    }
    guard requestAuthorizationIfNeeded() else {
        throw ProbeError.notAuthorized(AVCaptureDevice.authorizationStatus(for: .video))
    }

    try FileManager.default.createDirectory(at: options.outputURL, withIntermediateDirectories: true)
    let csvURL = options.outputURL.appendingPathComponent("results.csv")
    var csv = [
        "trial,delay_seconds,min_frames,actual_elapsed_seconds,actual_frame_count,width,height,mean_luminance,stddev_luminance,min_luminance,max_luminance,is_nearly_black,image,error"
    ]

    let total = options.trials * options.delays.count * options.frames.count
    var completed = 0
    for trial in 1...options.trials {
        for delay in options.delays {
            for frameTarget in options.frames {
                completed += 1
                let stem = String(format: "trial-%02d-delay-%.2f-frames-%03d", trial, delay, frameTarget)
                    .replacingOccurrences(of: ".", with: "p")
                let imageName = "\(stem).jpg"
                let imageURL = options.outputURL.appendingPathComponent(imageName)
                print("[\(completed)/\(total)] delay=\(delay)s frames=\(frameTarget) trial=\(trial)")

                switch runCapture(
                    minDelay: delay,
                    minFrames: frameTarget,
                    timeout: options.timeoutSeconds,
                    deviceID: options.deviceID
                ) {
                case .success(let result):
                    try result.data.write(to: imageURL, options: .atomic)
                    csv.append([
                        "\(trial)",
                        String(format: "%.3f", delay),
                        "\(frameTarget)",
                        String(format: "%.3f", result.elapsedSeconds),
                        "\(result.frameCount)",
                        "\(result.width)",
                        "\(result.height)",
                        String(format: "%.3f", result.stats.mean),
                        String(format: "%.3f", result.stats.standardDeviation),
                        String(format: "%.3f", result.stats.min),
                        String(format: "%.3f", result.stats.max),
                        result.stats.isNearlyBlack ? "true" : "false",
                        csvEscaped(imageName),
                        ""
                    ].joined(separator: ","))
                case .failure(let error):
                    csv.append([
                        "\(trial)",
                        String(format: "%.3f", delay),
                        "\(frameTarget)",
                        "",
                        "",
                        "",
                        "",
                        "",
                        "",
                        "",
                        "",
                        "",
                        "",
                        csvEscaped(String(describing: error))
                    ].joined(separator: ","))
                }
            }
        }
    }

    try (csv.joined(separator: "\n") + "\n").write(to: csvURL, atomically: true, encoding: .utf8)
    print("Wrote \(csvURL.path)")
} catch {
    fputs("camera_capture_matrix: \(error)\n", stderr)
    exit(1)
}
