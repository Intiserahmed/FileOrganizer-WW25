// ContentView.swift
//
// This file defines the user interface and the logic for suggesting
// new filenames based on content using a foundational model.

import SwiftUI
import FoundationModels // Import the framework

// A struct to represent a file and its properties.
// It's Identifiable so we can use it in a SwiftUI List.
struct FileItem: Identifiable, Hashable {
    let id = UUID()
    var originalName: String
    let content: String
    var suggestedName: String?
    var status: String = "Pending Correction"
}

// A @Generable struct to define the expected output from the language model.
@Generable
struct FileNameSuggestion: Equatable {
    @Guide(description: "A clear, descriptive filename in snake_case format, ending with the original '.txt' extension.")
    let newName: String
}

struct ContentView: View {
    // The model used for generating text.
    private let model = SystemLanguageModel.default
    
    // State variable to hold the list of files we are processing.
    @State private var files: [FileItem] = []
    
    // State variable to manage the overall status and button states.
    @State private var isCorrecting = false
    @State private var isRenaming = false
    @State private var modelAvailable: Bool = false
    
    // The location where mock files will be created and renamed.
    private var desktopUrl: URL? {
        FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
    }

    var body: some View {
        VStack(spacing: 15) {
            Text("AI File Renamer")
                .font(.largeTitle)
                .padding(.bottom, 5)
            
            if modelAvailable {
                // Main controls
                HStack(spacing: 10) {
                    Button(action: suggestNewNames) {
                        Label("Suggest New Filenames", systemImage: "sparkles")
                    }
                    .disabled(isCorrecting || files.isEmpty)
                    
                    Button(action: performRename) {
                        Label("Rename All Corrected", systemImage: "pencil.and.scribble")
                    }
                    .disabled(isCorrecting || isRenaming || files.allSatisfy { $0.suggestedName == nil })
                }
                .buttonStyle(.borderedProminent)
                
                // Progress and Status
                if isCorrecting {
                    ProgressView("Analyzing files...")
                        .progressViewStyle(.linear)
                }
                
                // List of files
                List($files) { $file in
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(file.originalName).fontWeight(.bold)
                            Text("Content: \"\(file.content)\"")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                            if let suggested = file.suggestedName {
                                Text("Suggestion: \(suggested)")
                                    .font(.callout)
                                    .foregroundStyle(.blue)
                            }
                            Text("Status: \(file.status)")
                                .font(.caption2)
                                .foregroundStyle(statusColor(for: file.status))
                        }
                        Spacer()
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))

            } else {
                // Fallback view if the model is not available
                ContentUnavailableView(
                    "Apple Intelligence Not Available",
                    systemImage: "exclamationmark.triangle",
                    description: Text("The language model needed for this feature is not available on this device or hasn't been enabled.")
                )
            }
        }
        .frame(minWidth: 600, minHeight: 400)
        .padding()
        .task {
            // Check for model availability and create mock files on first launch.
            switch model.availability {
            case .available:
                self.modelAvailable = true
            default:
                self.modelAvailable = false
            }
            
            if files.isEmpty {
                createMockFiles()
            }
        }
    }
    
    /// Sets the color of the status text based on its content.
    private func statusColor(for status: String) -> Color {
        if status.starts(with: "Error") { return .red }
        if status.starts(with: "Renamed") { return .green }
        return .secondary
    }

    /// Creates a set of temporary, poorly-named files on the desktop for the demo.
    private func createMockFiles() {
        guard let desktop = desktopUrl else { return }
        let mockData = [
            FileItem(originalName: "file_tmp_1.txt", content: "This document contains the final meeting minutes from the Q3 2025 financial review, discussing budget allocations and future projections."),
            FileItem(originalName: "stuff.txt", content: "A recipe for classic Italian lasagna. Ingredients include pasta, ground beef, ricotta cheese, mozzarella, and a rich tomato sauce."),
            FileItem(originalName: "mydoc_12345.txt", content: "Personal travel itinerary for a trip to Japan in spring 2026. Plans include visiting Tokyo for cherry blossoms and Kyoto for its historic temples.")
        ]
        
        for item in mockData {
            let fileUrl = desktop.appendingPathComponent(item.originalName)
            do {
                try item.content.write(to: fileUrl, atomically: true, encoding: .utf8)
            } catch {
                print("Failed to create mock file: \(error)")
            }
        }
        // Update the state to show the files in the UI.
        self.files = mockData
    }
    
    /// Uses the language model to generate a new filename.
    private func suggestNewNames() {
        // Prevent concurrent runs.
        guard !isCorrecting else { return }
        isCorrecting = true
        
        Task {
            // Use a task group to run corrections in parallel.
            await withTaskGroup(of: (UUID, String).self) { group in
                for file in files {
                    group.addTask {
                        // FIX: Create a new LanguageModelSession for each concurrent task.
                        // This prevents the "calling respond(to:) a second time" error.
                        let session = LanguageModelSession(model: model)
                        
                        let prompt = """
                        Analyze the following file content and suggest a clear, descriptive filename.
                        Original Name: "\(file.originalName)"
                        Content: "\(file.content)"
                        """
                        do {
                            // Use the streaming API to generate a response that conforms to our FileNameSuggestion struct.
                            let stream = session.streamResponse(
                                to: prompt,
                                generating: FileNameSuggestion.self
                            )

                            // We only need the final result from the stream.
                            var finalSuggestion: FileNameSuggestion.PartiallyGenerated?
                            for try await partial in stream {
                                finalSuggestion = partial
                            }

                            if let name = finalSuggestion?.newName {
                                return (file.id, name)
                            } else {
                                return (file.id, "Error: Could not generate a name.")
                            }
                        } catch {
                            return (file.id, "Error: \(error.localizedDescription)")
                        }
                    }
                }
                
                // As each task finishes, update the UI.
                for await (id, newName) in group {
                    if let index = files.firstIndex(where: { $0.id == id }) {
                        files[index].suggestedName = newName
                        files[index].status = newName.starts(with: "Error:") ? newName : "Correction Suggested"
                    }
                }
            }
            isCorrecting = false
        }
    }
    
    /// Renames the files on disk using the suggested names.
    private func performRename() {
        guard let desktop = desktopUrl else { return }
        isRenaming = true
        
        for i in 0..<files.count {
            guard let newName = files[i].suggestedName, !newName.starts(with: "Error:") else {
                continue // Skip files with errors or no suggestion.
            }
            
            let oldPath = desktop.appendingPathComponent(files[i].originalName)
            let newPath = desktop.appendingPathComponent(newName)
            
            do {
                try FileManager.default.moveItem(at: oldPath, to: newPath)
                files[i].status = "Renamed Successfully"
                files[i].originalName = newName // The new name is now the original for any future operations
            } catch {
                files[i].status = "Error: \(error.localizedDescription)"
            }
        }
        isRenaming = false
    }
}


#Preview {
    ContentView()
}
