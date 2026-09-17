import Foundation
import RemoteProtocol
import XCTest

final class RemoteProtocolTests: XCTestCase {
    func testM0FoundationMarker() {
        XCTAssertEqual(RemoteProtocolModule.name, "RemoteProtocol")
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
            "4D525031010000000100020000000200000000000000010000000000000002DEAD"
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
        unsupportedVersion[4] = 2
        assertProtocolError(.unsupportedVersion(major: 2, minor: 0)) {
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
        oversized[12] = 0x10
        oversized[13] = 0x00
        oversized[14] = 0x01
        assertProtocolError(.payloadTooLarge(actual: 1_048_577, maximum: 1_048_576)) {
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
            .clipboardOffer(
                ClipboardOfferMessage(generation: 12, origin: .viewer, textByteCount: 5, enabled: true)
            ),
            .clipboardText(ClipboardTextMessage(generation: 12, text: "hello")),
            .ping(PingMessage(nonce: 0x0102_0304_0506_0708)),
            .pong(PongMessage(nonce: 0x0102_0304_0506_0708)),
            .sessionState(
                SessionStateMessage(
                    state: .streaming,
                    permission: .granted,
                    focusEligible: true,
                    windowGeneration: 9
                )
            ),
            .error(ErrorMessage(code: .permissionMissing, retryable: true, detailCode: "screen-recording")),
            .close(CloseMessage(reason: .normal, detailCode: "done"))
        ]

        let goldenVectors: [MessageType: String] = [
            .hello: "0101010000000201000201000000010103010000000F4D616352656D6F74654170702D4D31040100000004001000000501000000040001000006010000000400100000",
            .capabilities: "010101000000060002000100060200000000040000078003000000000400000438040000000002003C",
            .pairingChallenge: "010101000000080102030405060708020100000006313233343536",
            .pairingConfirmation: "01010100000008010203040506070802010000000101030000000006313233343536",
            .sessionAuthorize: "01010100000001010200000000080000000000000009030100000006000200010002",
            .windowList: "0101010000005600010000005001010100000008000000000000002A020100000012636F6D2E6578616D706C652E456469746F72030000000008446F63756D656E7404010000000400000500050100000004000002D006010000000101",
            .windowSelection: "01010100000008000000000000002A0201000000080000000000000009",
            .streamConfig: "010101000000040000078002010000000400000438030100000002003C04010000000200010501000000080000000000000009",
            .videoConfig: "010101000000080000000000000009020100000003010203",
            .videoFrame: "010101000000080000000000000009020100000008000000000000006403010000000800000000000000650401000000040000078005010000000400000438060100000001010701000000050000000165",
            .inputEvent: "01010100000001030201000000080000000000000009030000000002014004000000000200B4070000000004FFFFFFFE08000000000400000004",
            .clipboardOffer: "01010100000008000000000000000C020100000001020301000000040000000504010000000101",
            .clipboardText: "01010100000008000000000000000C02010000000568656C6C6F",
            .ping: "010101000000080102030405060708",
            .pong: "010101000000080102030405060708",
            .sessionState: "010101000000010802010000000102030100000001010400000000080000000000000009",
            .error: "0101010000000200050201000000010103000000001073637265656E2D7265636F7264696E67",
            .close: "010101000000020001020000000004646F6E65"
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
        XCTAssertTrue(ProtocolVersion(major: 1, minor: 0).isCompatible())
        XCTAssertFalse(ProtocolVersion(major: 2, minor: 0).isCompatible())
        XCTAssertFalse(ProtocolVersion(major: 1, minor: 1).isCompatible())
        XCTAssertEqual(MessageType(rawValue: 0x7FFF), .unknown(0x7FFF))
        XCTAssertEqual(Capability(rawValue: 0x7FFF), .unknown(0x7FFF))

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
            Data(hex: "0101010000000400010007")
        )
        XCTAssertEqual(unknownOptional.capabilities, [.unknown(7)])
        XCTAssertTrue(unknownOptional.mandatoryCapabilities.isEmpty)
        assertProtocolError(.unknownMandatoryCapability(rawValue: 7)) {
            _ = try CapabilitiesMessage.decode(Data(hex: "0101010000000400018007"))
        }
        assertProtocolError(.invalidFieldValue(message: .capabilities, fieldID: 1)) {
            _ = try CapabilitiesMessage(capabilities: [.unknown(0)]).encoded()
        }

        assertProtocolError(.invalidLimits) {
            _ = try FrameParser(limits: ProtocolLimits(maxPayloadLength: 1, maxControlPayloadLength: 2))
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
