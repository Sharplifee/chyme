import SwiftUI
import AVFoundation

struct SoundPickerView: View {
    @Binding var selection: String
    @State private var player: AVAudioPlayer?
    var body: some View {
        List {
            Section {
                ForEach(ChymeSound.all) { sound in
                    Button {
                        selection = sound.name
                        player?.stop()
                        if let url = Bundle.main.url(forResource: sound.name.lowercased(), withExtension: "wav") {
                            player = try? AVAudioPlayer(contentsOf: url); player?.play()
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
            } footer: { Text("Tap a tone to preview. System uses the default iPhone alarm sound.") }
        }
        .navigationTitle("Sound")
        .onDisappear { player?.stop() }
    }
}
