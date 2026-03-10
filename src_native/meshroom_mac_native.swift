import Foundation
import RealityKit
import Metal

// A simple CLI to run Apple's Object Capture (PhotogrammetrySession)
// Arguments: <input_folder> <output_file.usdz> <detail_level>

@available(macOS 12.0, *)
func runObjectCapture() {
    let args = ProcessInfo.processInfo.arguments
    if args.count < 3 {
        print("Usage: meshroom_mac_native <input_folder> <output_file.usdz> [detail_level: preview|reduced|medium|full|raw]")
        exit(1)
    }
    
    let inputFolder = URL(fileURLWithPath: args[1])
    let outputFile = URL(fileURLWithPath: args[2])
    var detailLabel = "medium"
    if args.count >= 4 {
        detailLabel = args[3]
    }
    
    var detailLevel: PhotogrammetrySession.Request.Detail = .medium
    switch detailLabel.lowercased() {
    case "preview": detailLevel = .preview
    case "reduced": detailLevel = .reduced
    case "medium": detailLevel = .medium
    case "full": detailLevel = .full
    case "raw": detailLevel = .raw
    default: print("Unknown detail level '\(detailLabel)', using medium."); detailLevel = .medium
    }
    
    print("Starting Apple Native Photogrammetry (Metal)...")
    print("Input: \(inputFolder.path)")
    print("Output: \(outputFile.path)")
    print("Detail: \(detailLevel)")

    var session: PhotogrammetrySession!
    
    do {
        session = try PhotogrammetrySession(input: inputFolder, configuration: PhotogrammetrySession.Configuration())
    } catch {
        print("Error creating session: \(error)")
        exit(1)
    }
    
    let request = PhotogrammetrySession.Request.modelFile(url: outputFile, detail: detailLevel)

    Task {
        do {
            for try await output in session.outputs {
                switch output {
                case .processingComplete:
                    print("Processing Complete!")
                    exit(0)
                case .requestError(let req, let err):
                    print("Request Error for \(req): \(err)")
                    exit(1)
                case .requestComplete(_, let result):
                    print("Request Complete. Result generated.")
                case .requestProgress(_, let fraction):
                    let percentage = Int(fraction * 100)
                    print("Progress: \(percentage)%")
                case .inputComplete:
                    print("Input reading complete. Processing...")
                case .invalidSample(let id, let reason):
                    print("Invalid sample \(id): \(reason)")
                case .skippedSample(let id):
                    print("Skipped sample \(id)")
                case .automaticDownsampling:
                    print("Warning: Automatic downsampling applied due to resource limits.")
                case .processingCancelled:
                    print("Processing was cancelled.")
                    exit(1)
                @unknown default:
                    print("Unknown output received.")
                }
            }
        } catch {
            print("Session output error: \(error)")
            exit(1)
        }
    }
    
    do {
        try session.process(requests: [request])
    } catch {
        print("Error starting processing: \(error)")
        exit(1)
    }

    // Keep the command line tool running until processing finishes in the Task
    RunLoop.main.run()
}

if #available(macOS 12.0, *) {
    runObjectCapture()
} else {
    print("Apple Photogrammetry requires macOS 12.0 or newer.")
    exit(1)
}
