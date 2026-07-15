import AVFoundation

enum AVFoundationConsumer {
    static var commonAudioFormat: AVAudioCommonFormat {
        .pcmFormatFloat32
    }

    #if os(iOS)
        static var audioSessionCategory: AVAudioSession.Category {
            .ambient
        }
    #endif
}
