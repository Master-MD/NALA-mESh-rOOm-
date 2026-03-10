import SwiftUI
import RealityKit
import UniformTypeIdentifiers

@main
struct NALA3DStudioApp: App {
    var body: some SwiftUI.Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {} // Customize menu if needed
        }
    }
}

class PhotogrammetryManager: ObservableObject {
    @Published var isProcessing = false
    @Published var progress: Double = 0.0
    @Published var statusMessage: String = "Ready"
    @Published var selectedInputFolder: URL?
    @Published var selectedOutputFile: URL?
    @Published var detailLevel: PhotogrammetrySession.Request.Detail = .medium
    
    private var session: PhotogrammetrySession?
    
    @available(macOS 12.0, *)
    func startProcessing() {
        guard let input = selectedInputFolder, let output = selectedOutputFile else {
            statusMessage = "Please select an input folder and save location."
            return
        }
        
        isProcessing = true
        progress = 0.0
        statusMessage = "Initializing Apple Metal Engine..."
        
        do {
            session = try PhotogrammetrySession(input: input, configuration: PhotogrammetrySession.Configuration())
            
            let request = PhotogrammetrySession.Request.modelFile(url: output, detail: detailLevel)
            
            Task {
                do {
                    for try await outputEvent in session!.outputs {
                        await MainActor.run {
                            switch outputEvent {
                            case .requestProgress(_, let fraction):
                                self.progress = fraction
                                self.statusMessage = "Processing: \(Int(fraction * 100))%"
                            case .requestComplete(_, _):
                                self.progress = 1.0
                                self.statusMessage = "Processing Complete!"
                                self.isProcessing = false
                            case .requestError(_, let err):
                                self.statusMessage = "Error: \(err.localizedDescription)"
                                self.isProcessing = false
                            case .processingComplete:
                                self.statusMessage = "Session Finished."
                                self.isProcessing = false
                            case .processingCancelled:
                                self.statusMessage = "Cancelled."
                                self.isProcessing = false
                            default:
                                break
                            }
                        }
                    }
                } catch {
                    await MainActor.run {
                        self.statusMessage = "Output stream error: \(error.localizedDescription)"
                        self.isProcessing = false
                    }
                }
            }
            try session!.process(requests: [request])
            
        } catch {
            statusMessage = "Failed to start session: \(error.localizedDescription)"
            isProcessing = false
        }
    }
}

struct ContentView: View {
    @StateObject private var manager = PhotogrammetryManager()
    
    var body: some View {
        VStack(spacing: 20) {
            Text("NALA 3D Studio").font(.largeTitle).fontWeight(.bold)
            Text("Apple Silicon Native Engine").font(.subheadline).foregroundColor(.secondary)
            
            // Input Selection
            HStack {
                Text(manager.selectedInputFolder == nil ? "No folder selected" : manager.selectedInputFolder!.lastPathComponent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                
                Button("Select Photos Folder") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    if panel.runModal() == .OK {
                        manager.selectedInputFolder = panel.url
                    }
                }
                .disabled(manager.isProcessing)
            }
            .padding(.horizontal)
            
            // Output Selection
            HStack {
                Text(manager.selectedOutputFile == nil ? "No save location selected" : manager.selectedOutputFile!.lastPathComponent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                
                Button("Select Save File (.usdz)") {
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [UTType.usdz]
                    panel.nameFieldStringValue = "Model.usdz"
                    if panel.runModal() == .OK {
                        manager.selectedOutputFile = panel.url
                    }
                }
                .disabled(manager.isProcessing)
            }
            .padding(.horizontal)

            // Detail Selector
            Picker("Detail Level", selection: $manager.detailLevel) {
                Text("Preview").tag(PhotogrammetrySession.Request.Detail.preview)
                Text("Reduced").tag(PhotogrammetrySession.Request.Detail.reduced)
                Text("Medium").tag(PhotogrammetrySession.Request.Detail.medium)
                Text("Full").tag(PhotogrammetrySession.Request.Detail.full)
                Text("Raw").tag(PhotogrammetrySession.Request.Detail.raw)
            }
            .pickerStyle(SegmentedPickerStyle())
            .padding(.horizontal)
            .disabled(manager.isProcessing)
            
            // Status and Progress
            if manager.isProcessing || manager.progress > 0 {
                VStack {
                    ProgressView(value: manager.progress)
                        .progressViewStyle(LinearProgressViewStyle(tint: .green))
                        .padding(.horizontal)
                }
            }
            Text(manager.statusMessage).font(.headline).foregroundColor(.primary)
            
            // Action Button
            Button(action: {
                if #available(macOS 12.0, *) {
                    manager.startProcessing()
                }
            }) {
                Text(manager.isProcessing ? "Processing..." : "Generate 3D Model")
                    .font(.title2)
                    .fontWeight(.bold)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(manager.selectedInputFolder == nil || manager.selectedOutputFile == nil || manager.isProcessing ? Color.gray : Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
            }
            .disabled(manager.selectedInputFolder == nil || manager.selectedOutputFile == nil || manager.isProcessing)
            .padding()
        }
        .frame(minWidth: 500, minHeight: 400)
        .padding()
    }
}
