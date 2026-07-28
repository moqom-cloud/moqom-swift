import Testing

@testable import MoqomKit

// What can be tested here without a device is the *decision*, not the graph:
// which arrangement of the system each purpose asks for. That is worth pinning
// down on its own, because getting it wrong does not look like a configuration
// bug from the outside. A video call configured as a voice call plays out of the
// earpiece of a phone somebody is holding at arm's length, which reads as broken
// hardware, and a music broadcast configured as a call arrives sounding like a
// call, which reads as a bad codec.
@Suite("Audio graph purpose")
struct AudioGraphPurposeTests {
    @Test("a video call prefers the speaker, which is the case echo cancellation exists for")
    func videoCallIsSpeakerphone() {
        // The two conditions that make cancellation necessary rather than nice:
        // the loudspeaker is on, and the microphone is in the same room as it.
        #expect(AudioGraph.Purpose.videoCall.prefersSpeaker)
        #expect(AudioGraph.Purpose.videoCall.wantsVoiceProcessing)
    }

    @Test("a voice call leaves the earpiece alone")
    func voiceCallUsesTheReceiver() {
        // Held against a head. Forcing the speaker here would be loud, private
        // audio played into a room.
        #expect(!AudioGraph.Purpose.voiceCall.prefersSpeaker)
        #expect(AudioGraph.Purpose.voiceCall.wantsVoiceProcessing)
    }

    @Test("music turns voice processing off rather than tuning it")
    func musicBypassesVoiceProcessing() {
        // Cancellation does not arrive alone. It comes with gain control and
        // with suppression of anything that does not look like speech, and a
        // cymbal does not look like speech.
        #expect(!AudioGraph.Purpose.music.wantsVoiceProcessing)
        #expect(!AudioGraph.Purpose.music.prefersHeadsetInput)
    }

    @Test("a listener does not take the microphone")
    func listeningDoesNotCapture() {
        // The audience of an audio room. Taking a recording session here would
        // light the orange indicator for an app that is only listening, stop
        // playing the moment the screen locked, and hold the input device away
        // from every other app on the phone.
        #expect(!AudioGraph.Purpose.listening.capturesInput)
        #expect(!AudioGraph.Purpose.listening.wantsVoiceProcessing)
        #expect(!AudioGraph.Purpose.listening.prefersSpeaker)
    }

    #if os(iOS) || os(visionOS) || os(tvOS)
        @Test("listening is a playback session, and asks for none of the input options")
        func listeningIsPlayback() {
            // `setCategory` rejects the input options on `playback` rather than
            // ignoring them, and a rejected activation leaves a listener with no
            // audio at all — which is why this is worth pinning rather than
            // leaving to the reviewer to notice.
            #expect(AudioGraph.Purpose.listening.category == .playback)
            #expect(AudioGraph.Purpose.listening.options.isEmpty)

            for purpose in AudioGraph.Purpose.allCases where purpose.capturesInput {
                #expect(purpose.category == .playAndRecord)
            }
        }
    #endif

    @Test("every purpose that captures a voice asks for a headset microphone")
    func headsetInputFollowsVoice() {
        for purpose in AudioGraph.Purpose.allCases {
            #expect(
                purpose.prefersHeadsetInput == purpose.wantsVoiceProcessing,
                "\(purpose) disagrees with itself about whether it is capturing a voice"
            )
        }
    }
}
