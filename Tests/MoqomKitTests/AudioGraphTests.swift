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

    @Test("a broadcast keeps the voice capture and gives up the canceller")
    func broadcastTradesCancellationForVolume() {
        // The trade is not optional and not two decisions. Voice processing is
        // what puts a session on the in-call volume, and the in-call volume is
        // the one with a floor, so an output somebody can silence costs exactly
        // the canceller and nothing less.
        #expect(AudioGraph.Purpose.broadcast.capturesInput)
        #expect(!AudioGraph.Purpose.broadcast.wantsVoiceProcessing)

        // Still a voice, though, which is the difference from music: a host
        // wearing earbuds should be heard through them.
        #expect(AudioGraph.Purpose.broadcast.prefersHeadsetInput)
        #expect(AudioGraph.Purpose.broadcast.prefersSpeaker)
    }

    @Test("every purpose that captures a voice asks for a headset microphone")
    func headsetInputFollowsVoice() {
        // Written against `wantsVoiceProcessing` until `broadcast` existed, on
        // the assumption that the two were the same question. They are not:
        // a broadcast captures a voice and declines the processing, so the
        // proxy quietly asserted that a host's earbuds should be ignored.
        // What is actually meant is every capturing purpose except music.
        for purpose in AudioGraph.Purpose.allCases {
            let capturesAVoice = purpose.capturesInput && purpose != .music
            #expect(
                purpose.prefersHeadsetInput == capturesAVoice,
                "\(purpose) disagrees with itself about whether it is capturing a voice"
            )
        }
    }

    #if os(iOS) || os(visionOS) || os(tvOS)
        @Test("only the chat modes take the in-call volume")
        func mediaVolumeFollowsTheMode() {
            // The property the broadcast case exists for, pinned where it is
            // decided. Everything on a chat mode is a call as far as iOS is
            // concerned, and a call's output will not go to zero.
            for purpose in AudioGraph.Purpose.allCases {
                let isCall = purpose.mode == .voiceChat || purpose.mode == .videoChat
                #expect(
                    isCall == purpose.wantsVoiceProcessing,
                    "\(purpose) asks for one of the canceller and the call volume without the other"
                )
            }
            #expect(AudioGraph.Purpose.broadcast.mode == .default)
            #expect(AudioGraph.Purpose.broadcast.category == .playAndRecord)
        }
    #endif

    @Test("the microphone can be taken again after it is given back")
    func theMicrophoneComesBack() throws {
        // The mute button, in the only part of it that can be tested off a device: taking the
        // microphone, finishing with it, and taking it again. Nothing here starts the engine,
        // so no hardware is touched — but the refusal this pins down needed none either. The
        // graph allows one microphone at a time and nothing ever said one was finished with,
        // so the second time anybody went on stage they went live silent.
        let graph = AudioGraph(configuration: .init(purpose: .videoCall))
        _ = try graph.microphone()
        graph.releaseMicrophone()
        _ = try graph.microphone()

        // And giving back what was never taken is not an error, because the caller cannot
        // always know: stopping twice is ordinary.
        graph.releaseMicrophone()
        graph.releaseMicrophone()
    }

    /// The gain that exists because the system's does not reach zero while publishing.
    @Test("the room can be silenced, and cannot be turned up past unity")
    func theRoomCanBeSilenced() {
        let graph = AudioGraph(configuration: .init(purpose: .broadcast))
        #expect(graph.playbackVolume == 1, "a graph nobody has touched plays at the level it was sent at")

        graph.playbackVolume = 0
        #expect(graph.playbackVolume == 0, "silence is the whole point and 0.05 is not it")

        graph.playbackVolume = 4
        #expect(graph.playbackVolume == 1)
        graph.playbackVolume = -1
        #expect(graph.playbackVolume == 0)
    }
}
