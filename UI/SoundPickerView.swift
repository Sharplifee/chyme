import SwiftUI
import AVFoundation

struct SoundPickerView: View {
    @Binding var selection: String
    @State private var player: AVAudioPlayer?
    @State private var previewError: String?
    var body: some View {
        List {
            Section {
                ForEach(ChymeSound.all) { sound in
                    Button {
                        selection = sound.name
                        player?.stop()
                        if let url = Bundle.main.url(forResource: sound.name.lowercased(), withExtension: "wav") {
                            do {
                                player = try AVAudioPlayer(contentsOf: url)
                                if player?.play() != true { previewError = "This tone could not play. Check your audio output and try again." }
                            } catch { previewError = error.localizedDescription }
                        } else if sound.name != "System" {
                            previewError = "This tone’s audio file is missing."
                        }
                    } label: {
                        HStack {
                            Text(sound.name).foregroundStyle(.primary); Spacer()
                            if ChymeSound.resolved(selection) == sound.name {
                                Image(systemName: "checkmark").foregroundStyle(.orange)
                            }
                        }
                    }.accessibilityValue(ChymeSound.resolved(selection) == sound.name ? "Selected" : "Not selected")
                }
            } footer: { Text("Bell, Pulse, and Dawn include audio previews. System uses the default iPhone alarm sound and has no in-app preview. Apple’s Clock tone library is not provided through AlarmKit.") }
        }
        .navigationTitle("Sound")
        .onDisappear { player?.stop() }
        .alert("Couldn’t Preview Sound", isPresented: Binding(get: { previewError != nil }, set: { if !$0 { previewError = nil } })) {
            Button("OK") { previewError = nil }
        } message: { Text(previewError ?? "") }
    }
}
