import AVFoundation
import Photos
import UIKit
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins

class CameraModel: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {

    let session = AVCaptureSession()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private var currentPosition: AVCaptureDevice.Position = .back

    @Published var isRecording = false
    @Published var lastFrameImage: UIImage?

    private let ciContext = CIContext()
    
    override init() {
        super.init()
        checkPermissions()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppTermination),
            name: UIApplication.willTerminateNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppTermination),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
    }

    @objc private func handleAppTermination() {
        clearTemporaryVideos()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Permissions

    private func checkPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            requestAudioThenConfigure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
                    self.requestAudioThenConfigure()
                } else {
                    print("❌ Microphone access denied")
                }
            }
        default:
            print("❌ Camera access denied")
        }

        // Ask up front so saving doesn't stall on the first recording
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            if status != .authorized {
                print("⚠️ Photo library add access not granted — videos won't be saved")
            }
        }
    }

    private func requestAudioThenConfigure() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                // Proceed either way — video-only recording still works if mic is denied
                self.configureSession()
            }
        default:
            print("⚠️ Microphone access denied — recording video without audio")
            configureSession()
        }
    }

    // MARK: - Session setup

    private func configureSession() {
        sessionQueue.async {
            self.session.beginConfiguration()
            self.session.sessionPreset = .high

            guard let device = AVCaptureDevice.default(for: .video) else {
                print("❌ No video device found (are you on a simulator?)")
                self.session.commitConfiguration()
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(input) else {
                    print("❌ Could not add camera input")
                    self.session.commitConfiguration()
                    return
                }
                self.session.addInput(input)
            } catch {
                print("❌ Error creating device input: \(error)")
                self.session.commitConfiguration()
                return
            }

            // Microphone (optional — video still records fine without it)
            if let audioDevice = AVCaptureDevice.default(for: .audio) {
                do {
                    let audioInput = try AVCaptureDeviceInput(device: audioDevice)
                    if self.session.canAddInput(audioInput) {
                        self.session.addInput(audioInput)
                    } else {
                        print("⚠️ Could not add audio input")
                    }
                } catch {
                    print("⚠️ Error creating audio input: \(error)")
                }
            } else {
                print("⚠️ No audio device found")
            }

            if self.session.canAddOutput(self.movieOutput) {
                self.session.addOutput(self.movieOutput)
            } else {
                print("❌ Could not add movie output")
            }

            self.session.commitConfiguration()
            self.session.startRunning()
            print("✅ Session running: \(self.session.isRunning)")
        }
    }

    // MARK: - Recording

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        // clear the last image
        self.lastFrameImage = nil
        
        sessionQueue.async {
            let tempDir = FileManager.default.temporaryDirectory
            let url = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
            
            if let connection = self.movieOutput.connection(with: .video),
               connection.isVideoMirroringSupported {
               connection.automaticallyAdjustsVideoMirroring = false
               connection.isVideoMirrored = (self.currentPosition == .front)
           }
            
            if let connection = self.movieOutput.connection(with: .video) {
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .off
                }
            }
            
            self.movieOutput.startRecording(to: url, recordingDelegate: self)

            DispatchQueue.main.async { self.isRecording = true }
        }
    }

    private func stopRecording() {
        sessionQueue.async {
            self.movieOutput.stopRecording()
        }
    }

    // MARK: - AVCaptureFileOutputRecordingDelegate

    func fileOutput(_ output: AVCaptureFileOutput,
                     didFinishRecordingTo outputFileURL: URL,
                     from connections: [AVCaptureConnection],
                     error: Error?) {
        DispatchQueue.main.async { self.isRecording = false }

        if let error = error {
            print("❌ Recording error: \(error)")
        }

        extractLastFrame(from: outputFileURL)
        saveToPhotoLibrary(url: outputFileURL)
    }

    // MARK: - Post-processing

    func extractLastFrame(from url: URL) {
        let asset = AVAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true

        let duration = asset.duration
        // Grab a moment just before the very end to avoid a black/empty final frame
        let targetTime = CMTimeSubtract(duration, CMTime(value: 2, timescale: 30))
        let safeTime = targetTime.seconds > 0 ? targetTime : .zero

        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: safeTime)]) { _, cgImage, _, _, error in
            if let error = error {
                print("❌ Frame extraction error: \(error)")
                return
            }
            guard let cgImage = cgImage else { return }
            let image = UIImage(cgImage: cgImage)

            // Draw edge outlines on top of the frame so objects/people in the
            // ghost overlay are easier to line up against.
            let outline = self.edgeOutlineImage(from: image) ?? image

            DispatchQueue.main.async {
                self.lastFrameImage = outline
            }
        }
    }

    /// Produces a copy of `image` with outline strokes traced along the edges
    /// of objects/people drawn on top of it.
    /// - Parameters:
    ///   - lineColor: color of the traced edge lines (default white, reads well over most scenes)
    ///   - intensity: edge sensitivity passed to Core Image's edge filter; higher = more/brighter lines
    func edgeOutlineImage(from image: UIImage, lineColor: UIColor = .magenta, intensity: Double = 50.0) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        let inputImage = CIImage(cgImage: cgImage)

        // 1. Detect edges (Sobel-style). Result: bright lines on a near-black background.
        let edgesFilter = CIFilter.edges()
        edgesFilter.inputImage = inputImage
        edgesFilter.intensity = Float(intensity)

        guard let edgesOutput = edgesFilter.outputImage else { return nil }

        // 2. Convert the grayscale edge map into real alpha transparency:
        //    bright edge pixels -> opaque, dark/background pixels -> transparent.
        let maskToAlphaFilter = CIFilter.maskToAlpha()
        maskToAlphaFilter.inputImage = edgesOutput

        guard let alphaMasked = maskToAlphaFilter.outputImage else { return nil }

        // 3. Tint the (currently white) lines with the desired color while
        //    preserving the alpha we just created.
        let colorImage = CIImage(color: CIColor(color: lineColor)).cropped(to: alphaMasked.extent)

        let compositeFilter = CIFilter.sourceInCompositing()
        compositeFilter.inputImage = colorImage
        compositeFilter.backgroundImage = alphaMasked

        guard let tintedLines = compositeFilter.outputImage else { return nil }

        // 4. Draw those colored lines on top of the original image so the
        //    outline reinforces the photo instead of replacing it.
        let overCompositeFilter = CIFilter.sourceOverCompositing()
        overCompositeFilter.inputImage = tintedLines
        overCompositeFilter.backgroundImage = inputImage

        guard let combined = overCompositeFilter.outputImage,
              let outputCGImage = ciContext.createCGImage(combined, from: inputImage.extent) else {
            return nil
        }

        // Pixel data is already oriented upright (we generated it with
        // appliesPreferredTrackTransform = true), so orientation is .up here.
        return UIImage(cgImage: outputCGImage, scale: image.scale, orientation: .up)
    }

    private func saveToPhotoLibrary(url: URL) {
        PHPhotoLibrary.shared().performChanges({
            PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }) { success, error in
            if let error = error {
                print("❌ Save to Photos failed: \(error)")
            } else {
                print("✅ Video saved to Photos")
            }
            try? FileManager.default.removeItem(at: url)
        }
    }
    
    func flipCamera() {
        sessionQueue.async {
            self.session.beginConfiguration()

            // Remove the existing video input
            if let currentInput = self.session.inputs.first(where: {
                ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.video) == true
            }) {
                self.session.removeInput(currentInput)
            }

            self.currentPosition = (self.currentPosition == .back) ? .front : .back

            guard let newDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: self.currentPosition),
                  let newInput = try? AVCaptureDeviceInput(device: newDevice),
                  self.session.canAddInput(newInput) else {
                print("❌ Could not switch camera")
                self.session.commitConfiguration()
                return
            }

            self.session.addInput(newInput)
            self.session.commitConfiguration()
        }
    }
    
    // MARK: - Cleanup

    /// Removes any leftover temporary .mov files (from recordings or picker imports)
    /// so they don't accumulate across launches.
    func clearTemporaryVideos() {
        let tempDir = FileManager.default.temporaryDirectory
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: tempDir,
                includingPropertiesForKeys: nil
            )
            let movFiles = files.filter { $0.pathExtension.lowercased() == "mov" }
            for file in movFiles {
                try? FileManager.default.removeItem(at: file)
            }
            print("🧹 Cleared \(movFiles.count) temp video(s)")
        } catch {
            print("⚠️ Could not list temp directory: \(error)")
        }
    }
}

// could be used in a later update determine weather to flip horizontal images
extension AVAsset {
    /// Returns true if the video, after applying its preferred transform,
    /// displays wider than it is tall.
    func isVideoHorizontal() -> Bool {
        guard let track = tracks(withMediaType: .video).first else { return true }

        let size = track.naturalSize.applying(track.preferredTransform)
        let width = abs(size.width)
        let height = abs(size.height)

        return width > height
    }
}



