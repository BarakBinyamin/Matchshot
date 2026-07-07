import SwiftUI
import AVFoundation
import PhotosUI
import UniformTypeIdentifiers
import UIKit

// MARK: - Live camera preview (backed directly by AVCaptureVideoPreviewLayer)

class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as! AVCaptureVideoPreviewLayer
    }
}

struct VolumeButtonListener: View {
    let onPress: () -> Void

    private let audioSession = AVAudioSession.sharedInstance()

    @State private var observation: NSKeyValueObservation?

    var body: some View {
        Color.clear
            .onAppear {
                try? audioSession.setActive(true)

                observation = audioSession.observe(\.outputVolume, options: [.new]) { _, _ in
                    DispatchQueue.main.async {
                        onPress()
                    }
                }
            }
            .onDisappear {
                observation?.invalidate()
                observation = nil
            }
    }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.previewLayer.session = session
//        view.previewLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {}
}

// MARK: - Main view

struct ContentView: View {
    @StateObject private var camera = CameraModel()
    @State private var overlayOpacity: Double = 0.4
    @State private var showVideoPicker: Bool = false;
    
    var body: some View {
        ZStack {
            Color.black
            
            // Live feed
            CameraPreview(session: camera.session)
                .ignoresSafeArea()
            
            // Volume button events
            VolumeButtonListener(
                    onPress: camera.toggleRecording
                )
                
            // Ghost overlay of the last take's final frame
            if let lastFrame = camera.lastFrameImage {
                Image(uiImage: lastFrame)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity) 
                    .opacity(overlayOpacity)
                    .allowsHitTesting(false) // don't block controls underneath
                    .ignoresSafeArea()
            }

            VStack {
                Spacer()

                VStack(spacing: 16) {
                    // Transparency slider (only useful once there's an overlay)
                    if camera.lastFrameImage != nil {
                        HStack {
                            Image(systemName: "circle.lefthalf.filled")
                                .foregroundColor(.white)
                            Slider(value: $overlayOpacity, in: 0...1)
                            Image(systemName: "circle.fill")
                                .foregroundColor(.white)
                        }
                        .padding(.horizontal, 24)
                    }

                    // Record button
                    Button(action: { camera.toggleRecording() }) {
                        ZStack {
                            Circle()
                                .stroke(Color.white, lineWidth: 4)
                                .frame(width: 76, height: 76)

                            RoundedRectangle(cornerRadius: camera.isRecording ? 6 : 32)
                                .fill(Color.red)
                                .frame(
                                    width: camera.isRecording ? 30 : 64,
                                    height: camera.isRecording ? 30 : 64
                                )
                        }
                    }
                    .padding(.bottom, 80)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: camera.isRecording)
                }
            }.sheet(isPresented: $showVideoPicker) {
                VideoPicker { pickedURL in
                    camera.extractLastFrame(from: pickedURL)
                }
            }
        }.onTapGesture(count: 2) {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            camera.flipCamera()
        }
        .onLongPressGesture(minimumDuration: 0.5) {
             showVideoPicker = true
        }
        .ignoresSafeArea()
    }
}

#Preview {
    ContentView()
}

struct VideoPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .videos
        config.selectionLimit = 1

        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)

            guard let provider = results.first?.itemProvider,
                  provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) else { return }

            provider.loadFileRepresentation(forTypeIdentifier: UTType.movie.identifier) { url, error in
                guard let url = url else { return }

                // The URL is temporary and gets deleted after this closure returns,
                // so copy it somewhere durable first.
                let destination = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("mov")
                try? FileManager.default.copyItem(at: url, to: destination)

                DispatchQueue.main.async {
                    self.onPick(destination)
                }
            }
        }
    }
}

