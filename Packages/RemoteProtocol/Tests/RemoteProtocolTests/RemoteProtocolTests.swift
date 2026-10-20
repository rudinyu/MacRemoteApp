import Foundation
import RemoteProtocol
import XCTest

final class RemoteProtocolTests: XCTestCase {
    func testM0FoundationMarker() {
        XCTAssertEqual(RemoteProtocolModule.name, "RemoteProtocol")
    }

    func testTextInputEventRoundTripsAndRejectsUnsafeOrMixedPayloads() throws {
        XCTAssertEqual(Capability(rawValue: 0x000B), .textInput)
        XCTAssertEqual(Capability.textInput.rawValue, 0x000B)

        let committed = InputEventMessage(kind: .text, windowGeneration: 7, text: "你好，世界")
        let decoded = try InputEventMessage.decode(committed.encoded())
        XCTAssertEqual(decoded.kind, .text)
        XCTAssertEqual(decoded.text, "你好，世界")
        XCTAssertNil(decoded.keyCode)

        let maximal = String(repeating: "中", count: InputEventMessage.maximumTextBytes / 3)
        XCTAssertNoThrow(try InputEventMessage(kind: .text, windowGeneration: 7, text: maximal).encoded())

        for unsafe in ["", "line\nbreak", "tab\tstop", "\u{7F}", String(repeating: "a", count: 257)] {
            XCTAssertThrowsError(
                try InputEventMessage(kind: .text, windowGeneration: 7, text: unsafe).encoded(),
                "Unsafe text payload must be rejected: \(unsafe.debugDescription)"
            )
        }
        XCTAssertThrowsError(
            try InputEventMessage(kind: .text, windowGeneration: 7).encoded(),
            "A text event requires text."
        )
        XCTAssertThrowsError(
            try InputEventMessage(kind: .text, windowGeneration: 7, keyCode: 0, modifiers: 0, text: "a").encoded(),
            "A text event must not carry key fields."
        )
        XCTAssertThrowsError(
            try InputEventMessage(kind: .keyDown, windowGeneration: 7, keyCode: 0, modifiers: 0, text: "a").encoded(),
            "Only text events may carry text."
        )
    }

    func testPairingCommitRevealMessagesRoundTripAndBoundContributions() throws {
        let contribution = Data(repeating: 0xAB, count: 32)
        let challenge = PairingChallengeMessage(
            challengeID: 7,
            commitment: Data(repeating: 0xCD, count: 32)
        )
        let response = PairingResponseMessage(challengeID: 7, commitment: contribution)
        let verification = PairingVerificationMessage(challengeID: 7, contribution: contribution)
        let reveal = PairingRevealMessage(challengeID: 7, contribution: contribution)

        XCTAssertEqual(
            try MessagePayload.decode(
                messageType: .pairingChallenge,
                data: try challenge.encoded()
            ),
            .pairingChallenge(challenge)
        )
        XCTAssertEqual(
            try MessagePayload.decode(
                messageType: .pairingResponse,
                data: try response.encoded()
            ),
            .pairingResponse(response)
        )
        XCTAssertEqual(
            try MessagePayload.decode(
                messageType: .pairingVerification,
                data: try verification.encoded()
            ),
            .pairingVerification(verification)
        )
        XCTAssertEqual(
            try MessagePayload.decode(
                messageType: .pairingReveal,
                data: try reveal.encoded()
            ),
            .pairingReveal(reveal)
        )
        XCTAssertThrowsError(try PairingResponseMessage(challengeID: 7, commitment: Data([1])).encoded())
        XCTAssertThrowsError(try PairingVerificationMessage(challengeID: 7, contribution: Data([1])).encoded())
        XCTAssertThrowsError(try PairingRevealMessage(challengeID: 7, contribution: Data([1])).encoded())
    }

    func testWindowCatalogGenerationBindsListAndSelection() throws {
        let list = WindowListMessage(windows: [], catalogGeneration: 7)
        let selection = WindowSelectionMessage(
            windowIdentifier: 42,
            windowGeneration: 9,
            catalogGeneration: 7
        )

        XCTAssertEqual(
            try WindowListMessage.decode(try list.encoded()),
            list
        )
        XCTAssertEqual(
            try WindowSelectionMessage.decode(try selection.encoded()),
            selection
        )
        XCTAssertThrowsError(
            try WindowListMessage(windows: [], catalogGeneration: 0).encoded()
        )
        XCTAssertThrowsError(
            try WindowSelectionMessage(
                windowIdentifier: 42,
                windowGeneration: 9,
                catalogGeneration: 0
            ).encoded()
        )
    }

    func testHelloDeviceNameIsOptionalBoundedDisplayMetadata() throws {
        let namedHello = HelloMessage(
            protocolVersion: .current,
            role: .viewer,
            implementationIdentifier: "MacRemoteApp-Viewer-M10",
            limits: .default,
            deviceName: "Apple-Silicon-Viewer"
        )
        let decodedNamedHello = try HelloMessage.decode(try namedHello.encoded())
        XCTAssertEqual(decodedNamedHello, namedHello)

        let legacyHello = HelloMessage(
            protocolVersion: .current,
            role: .host,
            implementationIdentifier: "MacRemoteApp-Host-M10",
            limits: .default
        )
        XCTAssertNil(try HelloMessage.decode(legacyHello.encoded()).deviceName)

        for invalidName in ["", "  ", String(repeating: "x", count: 64), "bad\nname"] {
            let hello = HelloMessage(
                protocolVersion: .current,
                role: .viewer,
                implementationIdentifier: "MacRemoteApp-Viewer-M10",
                limits: .default,
                deviceName: invalidName
            )
            XCTAssertThrowsError(try hello.encoded(), "accepted invalid device name: \(invalidName)")
        }
    }

    func testEnvelopeGoldenVectorAndRoundTrip() throws {
        let envelope = try Envelope(
            channel: .control,
            messageType: .hello,
            flags: .acknowledgement,
            sequence: 1,
            timestamp: 2,
            payload: Data([0xDE, 0xAD])
        )
        let encoded = try envelope.encoded()

        XCTAssertEqual(
            encoded.hexString,
            "4D525031020000000100020000000200000000000000010000000000000002DEAD"
        )
        XCTAssertEqual(try Envelope.decode(encoded), envelope)
    }

    func testFrameParserHandlesPartialReadsAndIndependentChannels() throws {
        let controlHello = try Envelope(
            channel: .control,
            messageType: .hello,
            sequence: 100,
            timestamp: 1,
            payload: Data([0x01])
        ).encoded()
        let mediaConfig = try Envelope(
            channel: .media,
            messageType: .videoConfig,
            sequence: 7,
            timestamp: 2,
            payload: Data([0x02])
        ).encoded()
        let controlPing = try Envelope(
            channel: .control,
            messageType: .ping,
            sequence: 101,
            timestamp: 3,
            payload: Data([0x03])
        ).encoded()

        var parser = try FrameParser()
        var decoded: [Envelope] = []
        for byte in controlHello {
            decoded.append(contentsOf: try parser.append(Data([byte])))
        }
        XCTAssertEqual(decoded, [try Envelope.decode(controlHello)])
        XCTAssertEqual(parser.bufferedByteCount, 0)

        decoded.append(contentsOf: try parser.append(mediaConfig + controlPing))
        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded[1].channel, .media)
        XCTAssertEqual(decoded[1].sequence, 7)
        XCTAssertEqual(decoded[2].channel, .control)
        XCTAssertEqual(decoded[2].sequence, 101)
        XCTAssertEqual(parser.bufferedByteCount, 0)
    }

    func testFrameParserRejectsDuplicateAndOutOfOrderSequences() throws {
        let first = try Envelope(
            channel: .control,
            messageType: .ping,
            sequence: 10,
            timestamp: 1,
            payload: Data()
        ).encoded()
        let duplicate = try Envelope(
            channel: .control,
            messageType: .pong,
            sequence: 10,
            timestamp: 2,
            payload: Data()
        ).encoded()
        let outOfOrder = try Envelope(
            channel: .control,
            messageType: .pong,
            sequence: 12,
            timestamp: 3,
            payload: Data()
        ).encoded()

        var duplicateParser = try FrameParser()
        _ = try duplicateParser.append(first)
        assertProtocolError(.invalidSequence(expected: 11, actual: 10)) {
            _ = try duplicateParser.append(duplicate)
        }

        var orderParser = try FrameParser()
        _ = try orderParser.append(first)
        assertProtocolError(.invalidSequence(expected: 11, actual: 12)) {
            _ = try orderParser.append(outOfOrder)
        }
    }

    func testFrameParserAllowsForwardGapsOnlyOnMediaChannel() throws {
        let firstMedia = try Envelope(
            channel: .media,
            messageType: .videoFrame,
            sequence: 0,
            timestamp: 1,
            payload: Data([0x01])
        ).encoded()
        let gappedMedia = try Envelope(
            channel: .media,
            messageType: .videoFrame,
            sequence: 3,
            timestamp: 2,
            payload: Data([0x02])
        ).encoded()
        var mediaParser = try FrameParser()
        XCTAssertEqual(try mediaParser.append(firstMedia).count, 1)
        XCTAssertEqual(try mediaParser.append(gappedMedia).count, 1)

        let duplicateMedia = try Envelope(
            channel: .media,
            messageType: .videoFrame,
            sequence: 3,
            timestamp: 3,
            payload: Data([0x03])
        ).encoded()
        assertProtocolError(.invalidSequence(expected: 4, actual: 3)) {
            _ = try mediaParser.append(duplicateMedia)
        }
    }

    func testEnvelopeRejectsMalformedAndOversizedFrames() throws {
        let valid = try Envelope(
            channel: .control,
            messageType: .ping,
            sequence: 1,
            timestamp: 1,
            payload: Data([0x01])
        ).encoded()

        var invalidMagic = valid
        invalidMagic[0] = 0
        assertProtocolError(.invalidMagic) {
            _ = try Envelope.decode(invalidMagic)
        }

        var unsupportedVersion = valid
        unsupportedVersion[4] = 3
        assertProtocolError(.unsupportedVersion(major: 3, minor: 0)) {
            _ = try Envelope.decode(unsupportedVersion)
        }

        var invalidChannel = valid
        invalidChannel[6] = 9
        assertProtocolError(.invalidChannel(rawValue: 9)) {
            _ = try Envelope.decode(invalidChannel)
        }

        var unknownFlags = valid
        unknownFlags[10] = 0x80
        assertProtocolError(.unknownFlags(rawValue: 0x80)) {
            _ = try Envelope.decode(unknownFlags)
        }

        var unknownMandatoryMessage = valid
        unknownMandatoryMessage[7] = 0x7F
        unknownMandatoryMessage[8] = 0xFF
        unknownMandatoryMessage[10] = 0x08
        assertProtocolError(.unknownMandatoryMessageType(rawValue: 0x7FFF)) {
            _ = try Envelope.decode(unknownMandatoryMessage)
        }

        var oversized = valid
        oversized[11] = 0x00
        oversized[12] = 0x40
        oversized[13] = 0x00
        oversized[14] = 0x01
        assertProtocolError(.payloadTooLarge(actual: 4_194_305, maximum: 4_194_304)) {
            _ = try Envelope.decode(oversized)
        }

        assertProtocolError(.truncated(expected: Envelope.headerSize, actual: 3)) {
            _ = try Envelope.decode(Data([0x4D, 0x52, 0x50]))
        }
        assertProtocolError(.truncated(expected: valid.count, actual: valid.count - 1)) {
            _ = try Envelope.decode(valid.dropLast())
        }
        assertProtocolError(.trailingBytes(count: 1)) {
            _ = try Envelope.decode(valid + Data([0x00]))
        }
    }

    func testAllStableMessageFamiliesRoundTripDeterministically() throws {
        let messages: [MessagePayload] = [
            .hello(
                HelloMessage(
                    protocolVersion: .current,
                    role: .host,
                    implementationIdentifier: "MacRemoteApp-M1",
                    limits: .default
                )
            ),
            .capabilities(
                CapabilitiesMessage(
                    capabilities: [.pingPong, .h264Video],
                    maxVideoWidth: 1920,
                    maxVideoHeight: 1080,
                    maxFrameRate: 60
                )
            ),
            .pairingChallenge(
                PairingChallengeMessage(challengeID: 0x0102_0304_0506_0708, confirmationCode: "123456")
            ),
            .pairingConfirmation(
                PairingConfirmationMessage(challengeID: 0x0102_0304_0506_0708, accepted: true, confirmationCode: "123456")
            ),
            .sessionAuthorize(
                SessionAuthorizeMessage(
                    authorized: true,
                    windowGeneration: 9,
                    capabilities: [.windowSelection, .h264Video]
                )
            ),
            .windowList(
                WindowListMessage(
                    windows: [
                        WindowDescriptor(
                            identifier: 42,
                            applicationIdentifier: "com.example.Editor",
                            title: "Document",
                            width: 1280,
                            height: 720,
                            eligible: true
                        )
                    ]
                )
            ),
            .windowSelection(WindowSelectionMessage(windowIdentifier: 42, windowGeneration: 9)),
            .streamConfig(
                StreamConfigMessage(width: 1920, height: 1080, frameRate: 60, codec: .h264, generation: 9)
            ),
            .videoConfig(VideoConfigMessage(generation: 9, decoderConfiguration: Data([0x01, 0x02, 0x03]))),
            .videoFrame(
                VideoFrameMessage(
                    generation: 9,
                    captureTimestamp: 100,
                    presentationTimestamp: 101,
                    width: 1920,
                    height: 1080,
                    keyframe: true,
                    accessUnit: Data([0x00, 0x00, 0x00, 0x01, 0x65])
                )
            ),
            .inputEvent(
                InputEventMessage(
                    kind: .scroll,
                    windowGeneration: 9,
                    x: 320,
                    y: 180,
                    deltaX: -2,
                    deltaY: 4
                )
            ),
            .inputSourceSelection(
                InputSourceSelectionMessage(
                    windowGeneration: 9,
                    requestID: 0x0102_0304_0506_0708,
                    kind: .english,
                    sourceIdentifier: "ABC"
                )
            ),
            .inputSourceAcknowledgement(
                InputSourceAcknowledgementMessage(
                    windowGeneration: 9,
                    requestID: 0x0102_0304_0506_0708,
                    status: .applied
                )
            ),
            .clipboardOffer(
                ClipboardOfferMessage(generation: 12, origin: .viewer, textByteCount: 5, enabled: true)
            ),
            .clipboardText(ClipboardTextMessage(generation: 12, text: "hello")),
            .clipboardAcknowledgement(
                ClipboardAcknowledgementMessage(
                    generation: 12,
                    origin: .viewer,
                    accepted: true,
                    reason: .accepted
                )
            ),
            .ping(PingMessage(nonce: 0x0102_0304_0506_0708)),
            .pong(PongMessage(nonce: 0x0102_0304_0506_0708)),
            .sessionState(
                SessionStateMessage(
                    state: .streaming,
                    permission: .granted,
                    focusEligible: true,
                    windowGeneration: 9,
                    controlState: .active,
                    processTargetEligible: true
                )
            ),
            .error(ErrorMessage(code: .permissionMissing, retryable: true, detailCode: "screen-recording")),
            .close(CloseMessage(reason: .normal, detailCode: "done")),
            .keyframeRequest(KeyframeRequestMessage(generation: 9, reason: .mediaGap)),
            .receiverReport(
                ReceiverReportMessage(
                    generation: 9,
                    queuingDelayMicroseconds: 42_000,
                    receivedFrames: 30,
                    discardedFrames: 2
                )
            )
        ]

        let goldenVectors: [MessageType: String] = [
            // Field 4 advertises the 4 MiB default payload limit.
            .hello: "0101010000000202000201000000010103010000000F4D616352656D6F74654170702D4D3104010000000400400000050100000004000100000601000000040000FFEB",
            .capabilities: "010101000000060002000100060200000000040000078003000000000400000438040000000002003C",
            .pairingChallenge: "010101000000080102030405060708020100000006313233343536",
            .pairingConfirmation: "01010100000008010203040506070802010000000101030000000006313233343536",
            .sessionAuthorize: "01010100000001010200000000080000000000000009030100000006000200010002",
            .windowList: "0101010000005600010000005001010100000008000000000000002A020100000012636F6D2E6578616D706C652E456469746F72030000000008446F63756D656E7404010000000400000500050100000004000002D0060100000001010201000000080000000000000001",
            .windowSelection: "01010100000008000000000000002A02010000000800000000000000090301000000080000000000000001",
            .streamConfig: "010101000000040000078002010000000400000438030100000002003C04010000000200010501000000080000000000000009",
            .videoConfig: "010101000000080000000000000009020100000003010203",
            .videoFrame: "010101000000080000000000000009020100000008000000000000006403010000000800000000000000650401000000040000078005010000000400000438060100000001010701000000050000000165",
            .inputEvent: "01010100000001030201000000080000000000000009030000000002014004000000000200B4070000000004FFFFFFFE08000000000400000004",
            .inputSourceSelection: "010101000000080000000000000009020100000008010203040506070803010000000101040100000003414243",
            .inputSourceAcknowledgement: "010101000000080000000000000009020100000008010203040506070803010000000101",
            .clipboardOffer: "01010100000008000000000000000C020100000001020301000000040000000504010000000101",
            .clipboardText: "01010100000008000000000000000C02010000000568656C6C6F",
            .clipboardAcknowledgement: "01010100000008000000000000000C020100000001020301000000010104010000000101",
            .ping: "010101000000080102030405060708",
            .pong: "010101000000080102030405060708",
            .sessionState: "0101010000000108020100000001020301000000010104000000000800000000000000090500000000010406000000000101",
            .error: "0101010000000200050201000000010103000000001073637265656E2D7265636F7264696E67",
            .close: "010101000000020001020000000004646F6E65",
            .keyframeRequest: "01010100000008000000000000000902010000000101",
            .receiverReport: "0101010000000800000000000000090201000000040000A4100301000000040000001E04010000000400000002"
        ]

        for message in messages {
            let encoded = try message.encoded()
            XCTAssertEqual(
                encoded.hexString,
                goldenVectors[message.messageType],
                "golden vector changed for \(message.messageType)"
            )
            let decoded = try MessagePayload.decode(
                messageType: message.messageType,
                data: encoded
            )
            XCTAssertEqual(decoded, message, "round-trip failed for \(message.messageType)")
            XCTAssertEqual(try decoded.encoded(), encoded, "non-deterministic encoding for \(message.messageType)")
        }
    }

    func testMessageUnknownOptionalFieldIsIgnoredAndMandatoryFieldFailsClosed() throws {
        let base = try PingMessage(nonce: 7).encoded()
        let optionalUnknown = base + Data(hex: "FA0000000001FF")
        XCTAssertEqual(
            try PingMessage.decode(optionalUnknown),
            PingMessage(nonce: 7)
        )

        let mandatoryUnknown = base + Data(hex: "FA0100000001FF")
        assertProtocolError(.unknownMandatoryField(message: .ping, fieldID: 250)) {
            _ = try PingMessage.decode(mandatoryUnknown)
        }
    }

    func testKeyframeRequestRejectsUnknownReasonAndUsesControlChannel() throws {
        XCTAssertEqual(MessageType(rawValue: 0x0017), .keyframeRequest)
        XCTAssertEqual(MessageType.keyframeRequest.defaultChannel, .control)
        XCTAssertEqual(Capability(rawValue: 0x0007), .keyframeRequest)
        XCTAssertEqual(Capability(rawValue: 0x0008), .receiverReport)
        XCTAssertEqual(MessageType(rawValue: 0x0018), .receiverReport)
        XCTAssertEqual(MessageType.receiverReport.defaultChannel, .control)
        var encoded = try KeyframeRequestMessage(generation: 9, reason: .decodeFailure).encoded()
        encoded[encoded.count - 1] = 0x7F
        XCTAssertThrowsError(
            try MessagePayload.decode(messageType: .keyframeRequest, data: encoded)
        ) { error in
            XCTAssertEqual(
                error as? ProtocolError,
                .invalidFieldValue(message: .keyframeRequest, fieldID: 2)
            )
        }
    }

    func testPongOptionalReceiverTimestampRoundTripsAndLegacyDefaultsToNil() throws {
        let timestamped = PongMessage(
            nonce: 7,
            receiverTimestampNanoseconds: 42
        )
        XCTAssertEqual(
            try PongMessage.decode(timestamped.encoded()),
            timestamped
        )
        XCTAssertNil(
            try PongMessage.decode(PongMessage(nonce: 7).encoded())
                .receiverTimestampNanoseconds
        )
    }

    func testMessageMalformedFieldsAndBoundsFailPredictably() throws {
        let duplicateField = Data(hex: "0101010000000101010000000102")
        assertProtocolError(.duplicateField(message: .ping, fieldID: 1)) {
            _ = try PingMessage.decode(duplicateField)
        }

        let outOfOrderField = Data(hex: "0102010000000101010000000102")
        assertProtocolError(.fieldsOutOfOrder(message: .ping, previous: 2, current: 1)) {
            _ = try PingMessage.decode(outOfOrderField)
        }

        let invalidUTF8 = Data(hex: "010101000000080000000000000001020100000001FF")
        assertProtocolError(.invalidUTF8(message: .clipboardText, fieldID: 2)) {
            _ = try ClipboardTextMessage.decode(
                invalidUTF8,
                using: ProtocolLimits(maxClipboardTextBytes: 4)
            )
        }

        assertProtocolError(.payloadTooLarge(actual: 5, maximum: 4)) {
            _ = try ClipboardTextMessage(
                generation: 1,
                text: Data([0x31, 0x32, 0x33, 0x34, 0x35])
            ).encoded(using: ProtocolLimits(maxClipboardTextBytes: 4))
        }

        let malformedCapabilityList = Data(hex: "01010100000006000200020001")
        assertProtocolError(.invalidFieldValue(message: .capabilities, fieldID: 1)) {
            _ = try CapabilitiesMessage.decode(malformedCapabilityList)
        }
    }

    func testCapabilitiesAreCanonicalAndEnvelopeCanCarryTypedMessages() throws {
        let message = MessagePayload.capabilities(
            CapabilitiesMessage(capabilities: [.pingPong, .h264Video])
        )
        let envelope = try Envelope(
            message: message,
            sequence: 4,
            timestamp: 5
        )
        XCTAssertEqual(envelope.channel, .control)
        XCTAssertEqual(try envelope.decodedMessage(), message)
        XCTAssertEqual(
            try CapabilitiesMessage(capabilities: [.pingPong, .h264Video]).encoded().hexString,
            "01010100000006000200010006"
        )
    }

    func testProtocolVersionCapabilityAndLimitsRules() throws {
        XCTAssertEqual(ProtocolLimits.default.maxControlPayloadLength, 65_536)
        XCTAssertEqual(ProtocolLimits.default.maxClipboardTextBytes, 65_515)
        XCTAssertTrue(ProtocolVersion(major: 2, minor: 0).isCompatible())
        XCTAssertFalse(ProtocolVersion(major: 1, minor: 0).isCompatible())
        XCTAssertFalse(ProtocolVersion(major: 2, minor: 1).isCompatible())
        XCTAssertEqual(MessageType(rawValue: 0x7FFF), .unknown(0x7FFF))
        XCTAssertEqual(Capability(rawValue: 0x7FFF), .unknown(0x7FFF))
        XCTAssertEqual(MessageType(rawValue: 0x0019), .inputSourceSelection)
        XCTAssertEqual(MessageType(rawValue: 0x001A), .inputSourceAcknowledgement)
        XCTAssertEqual(Capability(rawValue: 0x0009), .inputSourceSync)
        XCTAssertEqual(Capability(rawValue: 0x000A), .backgroundControl)
        XCTAssertEqual(Capability.backgroundControl.rawValue, 0x000A)
        XCTAssertEqual(ControlAuthorizationState(rawValue: 7), .negotiating)
        XCTAssertEqual(ProtocolVersion.current, ProtocolVersion(major: 2, minor: 0))

        let knownMandatory = CapabilitiesMessage(
            capabilities: [.h264Video],
            mandatoryCapabilities: [.h264Video]
        )
        XCTAssertEqual(
            try knownMandatory.encoded().hexString,
            "0101010000000400018001"
        )
        XCTAssertEqual(
            try CapabilitiesMessage.decode(try knownMandatory.encoded()),
            knownMandatory
        )

        let unknownOptional = try CapabilitiesMessage.decode(
            Data(hex: "0101010000000400010040")
        )
        XCTAssertEqual(unknownOptional.capabilities, [.unknown(0x0040)])
        XCTAssertTrue(unknownOptional.mandatoryCapabilities.isEmpty)
        assertProtocolError(.unknownMandatoryCapability(rawValue: 0x0040)) {
            _ = try CapabilitiesMessage.decode(Data(hex: "0101010000000400018040"))
        }
        assertProtocolError(.invalidFieldValue(message: .capabilities, fieldID: 1)) {
            _ = try CapabilitiesMessage(capabilities: [.unknown(0)]).encoded()
        }

        assertProtocolError(.invalidLimits) {
            _ = try FrameParser(limits: ProtocolLimits(maxPayloadLength: 1, maxControlPayloadLength: 2))
        }
    }

    func testBackgroundControlTargetEligibilityIsIndependentOfForegroundFlag() throws {
        let status = SessionStateMessage(
            state: .streaming,
            permission: .granted,
            focusEligible: false,
            windowGeneration: 9,
            controlState: .active,
            processTargetEligible: true,
            controlGeneration: 12
        )

        let decoded = try SessionStateMessage.decode(status.encoded())

        XCTAssertFalse(decoded.focusEligible)
        XCTAssertEqual(decoded.controlState, .active)
        XCTAssertEqual(decoded.processTargetEligible, true)
        XCTAssertEqual(decoded.controlGeneration, 12)
        var zeroControlGeneration = try status.encoded()
        zeroControlGeneration.replaceSubrange(
            (zeroControlGeneration.count - MemoryLayout<UInt64>.size)..<zeroControlGeneration.count,
            with: Data(repeating: 0, count: MemoryLayout<UInt64>.size)
        )
        assertProtocolError(.invalidFieldValue(message: .sessionState, fieldID: 7)) {
            _ = try SessionStateMessage.decode(zeroControlGeneration)
        }
    }

    func testP6InputControlGenerationRoundTripsAndRejectsZero() throws {
        let event = InputEventMessage(
            kind: .keyDown,
            windowGeneration: 9,
            keyCode: 42,
            modifiers: 0,
            controlGeneration: 12
        )
        XCTAssertEqual(try InputEventMessage.decode(event.encoded()), event)
        var zeroEventGeneration = try event.encoded()
        zeroEventGeneration.replaceSubrange(
            (zeroEventGeneration.count - MemoryLayout<UInt64>.size)..<zeroEventGeneration.count,
            with: Data(repeating: 0, count: MemoryLayout<UInt64>.size)
        )
        assertProtocolError(.invalidFieldValue(message: .inputEvent, fieldID: 11)) {
            _ = try InputEventMessage.decode(zeroEventGeneration)
        }

        let source = InputSourceSelectionMessage(
            windowGeneration: 9,
            requestID: 3,
            kind: .english,
            sourceIdentifier: "com.apple.keylayout.US",
            controlGeneration: 12
        )
        XCTAssertEqual(try InputSourceSelectionMessage.decode(source.encoded()), source)
        var zeroSourceGeneration = try source.encoded()
        zeroSourceGeneration.replaceSubrange(
            (zeroSourceGeneration.count - MemoryLayout<UInt64>.size)..<zeroSourceGeneration.count,
            with: Data(repeating: 0, count: MemoryLayout<UInt64>.size)
        )
        assertProtocolError(.invalidFieldValue(message: .inputSourceSelection, fieldID: 5)) {
            _ = try InputSourceSelectionMessage.decode(zeroSourceGeneration)
        }

        assertProtocolError(.invalidFieldValue(message: .inputEvent, fieldID: 11)) {
            _ = try InputEventMessage(
                kind: .keyDown,
                windowGeneration: 9,
                keyCode: 42,
                modifiers: 0,
                controlGeneration: 0
            ).encoded()
        }
        assertProtocolError(.invalidFieldValue(message: .inputSourceSelection, fieldID: 5)) {
            _ = try InputSourceSelectionMessage(
                windowGeneration: 9,
                requestID: 3,
                kind: .english,
                sourceIdentifier: "com.apple.keylayout.US",
                controlGeneration: 0
            ).encoded()
        }
        assertProtocolError(.invalidFieldValue(message: .sessionState, fieldID: 7)) {
            _ = try SessionStateMessage(
                state: .streaming,
                permission: .granted,
                focusEligible: false,
                windowGeneration: 9,
                controlState: .active,
                processTargetEligible: true,
                controlGeneration: 0
            ).encoded()
        }
    }

    func testLegacySessionStateWithoutControlFieldsDecodesNil() throws {
        let legacyPayload = Data(
            hex: "010101000000010802010000000102030100000001010400000000080000000000000009"
        )

        let decoded = try SessionStateMessage.decode(legacyPayload)

        XCTAssertEqual(decoded.state, .streaming)
        XCTAssertEqual(decoded.permission, .granted)
        XCTAssertTrue(decoded.focusEligible)
        XCTAssertEqual(decoded.windowGeneration, 9)
        XCTAssertNil(decoded.controlState)
        XCTAssertNil(decoded.processTargetEligible)
        XCTAssertNil(decoded.controlGeneration)
    }

    func testInputSourceMessagesEnforceBoundsAndRejectControlCharacters() throws {
        let validMaximumIdentifier = String(repeating: "a", count: 256)
        let selection = InputSourceSelectionMessage(
            windowGeneration: 1,
            requestID: 1,
            kind: .chinese,
            sourceIdentifier: validMaximumIdentifier
        )
        XCTAssertLessThanOrEqual(try selection.encoded().count, InputSourceSelectionMessage.maximumPayloadLength)
        XCTAssertEqual(
            try InputSourceSelectionMessage.decode(selection.encoded()),
            selection
        )

        for invalidIdentifier in [String(repeating: "a", count: 257), "", "line\nbreak", "nul\0byte", "\u{0085}"] {
            let invalid = InputSourceSelectionMessage(
                windowGeneration: 1,
                requestID: 1,
                kind: .english,
                sourceIdentifier: invalidIdentifier
            )
            assertProtocolError(.invalidFieldValue(message: .inputSourceSelection, fieldID: 4)) {
                _ = try invalid.encoded()
            }
        }

        let zeroGeneration = InputSourceSelectionMessage(
            windowGeneration: 0,
            requestID: 1,
            kind: .english,
            sourceIdentifier: "com.apple.keylayout.US"
        )
        assertProtocolError(.invalidFieldValue(message: .inputSourceSelection, fieldID: 1)) {
            _ = try zeroGeneration.encoded()
        }
        let zeroRequest = InputSourceAcknowledgementMessage(
            windowGeneration: 1,
            requestID: 0,
            status: .failed
        )
        assertProtocolError(.invalidFieldValue(message: .inputSourceAcknowledgement, fieldID: 2)) {
            _ = try zeroRequest.encoded()
        }

        assertProtocolError(.controlPayloadTooLarge(actual: 513, maximum: 512)) {
            _ = try InputSourceAcknowledgementMessage.decode(Data(repeating: 0, count: 513))
        }

        let narrowLimits = ProtocolLimits(
            maxPayloadLength: 1_024,
            maxControlPayloadLength: 32,
            maxClipboardTextBytes: 11,
            maxFieldLength: 1_024,
            maxIdentifierBytes: 256
        )
        assertProtocolError(.controlPayloadTooLarge(actual: 45, maximum: 32)) {
            _ = try InputSourceSelectionMessage(
                windowGeneration: 1,
                requestID: 1,
                kind: .english,
                sourceIdentifier: "ABC"
            ).encoded(using: narrowLimits)
        }
    }

    func testDefaultClipboardLimitFitsTheControlEnvelope() throws {
        let text = Data(repeating: 0x61, count: ProtocolLimits.default.maxClipboardTextBytes)
        let envelope = try Envelope(
            message: .clipboardText(ClipboardTextMessage(generation: 1, text: text)),
            sequence: 1,
            timestamp: 1
        )

        XCTAssertEqual(envelope.payload.count, ProtocolLimits.default.maxControlPayloadLength)
        XCTAssertLessThanOrEqual(
            try envelope.encoded().count - Envelope.headerSize,
            ProtocolLimits.default.maxControlPayloadLength
        )
        assertProtocolError(.payloadTooLarge(actual: 65_516, maximum: 65_515)) {
            _ = try ClipboardTextMessage(
                generation: 1,
                text: Data(repeating: 0x61, count: 65_516)
            ).encoded()
        }
    }

    func testClipboardStatusOfferUsesOptionalHasTextField() throws {
        let offer = ClipboardOfferMessage(
            generation: 4,
            origin: .host,
            textByteCount: 0,
            enabled: true,
            hasText: false
        )
        let encoded = try offer.encoded()
        let decoded = try ClipboardOfferMessage.decode(encoded)
        XCTAssertEqual(decoded, offer)
        XCTAssertNotEqual(encoded, try ClipboardOfferMessage(
            generation: 4,
            origin: .host,
            textByteCount: 0,
            enabled: true
        ).encoded())
    }

    func testLegacyDisabledClipboardOfferDefaultsToNoText() throws {
        let inferredStatus = ClipboardOfferMessage(
            generation: 5,
            origin: .host,
            textByteCount: 0,
            enabled: false
        )
        XCTAssertFalse(inferredStatus.hasText)
        XCTAssertEqual(
            try inferredStatus.encoded(),
            try ClipboardOfferMessage(
                generation: 5,
                origin: .host,
                textByteCount: 0,
                enabled: false,
                hasText: false
            ).encoded()
        )

        let legacyOffer = try ClipboardOfferMessage(
            generation: 5,
            origin: .host,
            textByteCount: 0,
            enabled: false,
            hasText: false
        ).encoded().dropLast(7)

        let decoded = try ClipboardOfferMessage.decode(Data(legacyOffer))
        XCTAssertFalse(decoded.enabled)
        XCTAssertFalse(decoded.hasText)
        XCTAssertEqual(decoded.textByteCount, 0)
    }

    func testClipboardAcknowledgementRejectsInconsistentReason() throws {
        assertProtocolError(.invalidFieldValue(message: .clipboardAcknowledgement, fieldID: 4)) {
            _ = try ClipboardAcknowledgementMessage(
                generation: 1,
                origin: .host,
                accepted: true,
                reason: .conflict
            ).encoded()
        }
    }
}

private func assertProtocolError(
    _ expected: ProtocolError,
    operation: () throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    do {
        try operation()
        XCTFail("expected \(expected), but operation succeeded", file: file, line: line)
    } catch let error as ProtocolError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("expected ProtocolError \(expected), received \(error)", file: file, line: line)
    }
}

private extension Data {
    init(hex: String) {
        let characters = Array(hex)
        precondition(characters.count.isMultiple(of: 2), "hex string must contain whole bytes")
        var result = Data()
        result.reserveCapacity(characters.count / 2)
        for index in stride(from: 0, to: characters.count, by: 2) {
            let byteString = String(characters[index ... index + 1])
            guard let byte = UInt8(byteString, radix: 16) else {
                preconditionFailure("invalid hex byte: \(byteString)")
            }
            result.append(byte)
        }
        self = result
    }

    var hexString: String {
        map { String(format: "%02X", $0) }.joined()
    }
}
