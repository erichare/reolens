import Foundation
import OSLog

private let log = Logger(subsystem: "com.reolens.baichuan", category: "login")

extension BaichuanClient {

    /// Two-step Baichuan login:
    ///
    ///   1. Send a legacy `LoginUpgrade` (msg_id=1, class=0x6514, body empty)
    ///      with `response_code = 0xDC{0x00|0x01|0x02|0x12}` indicating the
    ///      highest encryption the client supports. The camera replies with
    ///      its negotiated level (high byte 0xDD) and an XML payload
    ///      containing a `<nonce>` value.
    ///
    ///   2. Send a modern login (msg_id=1, class=0x6414) carrying
    ///      `<LoginUser>` with username and password each MD5'd against
    ///      `{value}{nonce}`, uppercased, and truncated to 31 chars.
    ///
    /// On success the camera replies with `response_code == 200` and a
    /// `<DeviceInfo>` payload, and the negotiated cipher takes effect for
    /// subsequent messages.
    /// Default max encryption is `.fullAes` — that's the request byte
    /// Neolink uses for "max = AES" (see `crates/core/src/bc_protocol/login.rs`).
    /// Sending `.aes` (0xDC02) instead is silently ignored by Reolink hubs.
    @discardableResult
    public func login(maxEncryption: BcEncryptionLevel = .fullAes) async throws -> String {
        log.info("Baichuan login phase 1: legacy upgrade (max enc=\(String(maxEncryption.rawValue, radix: 16, uppercase: true), privacy: .public))")

        let msgNum = nextMessageNumber()
        let upgradeHeader = BcHeader(
            msgID: BcMessageID.login,
            bodyLength: 0,
            channelID: 0,
            streamType: 0,
            msgNum: msgNum,
            responseCode: maxEncryption.requestByte,
            msgClass: BcConstants.classLegacy
        )
        let upgrade = BcMessage(header: upgradeHeader, body: Data())
        log.debug("Sending legacy LoginUpgrade msgNum=\(msgNum)")
        let upgradeReply = try await sendAndAwait(upgrade, timeout: 8, stage: "legacy-upgrade")
        log.info("Got upgrade reply: msgID=\(upgradeReply.header.msgID) class=0x\(String(upgradeReply.header.msgClass, radix: 16)) code=0x\(String(upgradeReply.header.responseCode, radix: 16)) bodyLen=\(upgradeReply.header.bodyLength)")

        guard let negotiated = upgradeReply.header.negotiatedEncryption else {
            throw BaichuanError.loginFailed(reason: "no encryption negotiation in reply (code=0x\(String(upgradeReply.header.responseCode, radix: 16)))")
        }
        log.info("Negotiated encryption: \(String(describing: negotiated), privacy: .public)")

        // Decrypted body should be XML containing <nonce>...
        // Note: the upgrade reply is XOR-encrypted because the AES key isn't
        // derivable until we have the nonce. So the decode currently used
        // .unencrypted; we need to try BCEncrypt explicitly.
        let xorDecrypted = BcCipher.bcEncrypt.decrypt(upgradeReply.body, encOffset: UInt32(upgradeReply.header.channelID & 0x0F))
        let xmlData = looksLikeXML(xorDecrypted) ? xorDecrypted : upgradeReply.body
        guard let nonce = BcXmlBody.extractNonce(from: xmlData) else {
            throw BaichuanError.loginFailed(reason: "no <nonce> in reply XML: \(String(data: xmlData.prefix(200), encoding: .utf8) ?? "<binary>")")
        }
        log.debug("Got nonce: \(nonce, privacy: .private)")

        // Pick the cipher for subsequent messages.
        switch negotiated {
        case .unencrypted: setCipher(.unencrypted)
        case .bcEncrypt: setCipher(.bcEncrypt)
        case .aes, .fullAes:
            let key = BcCipher.deriveAESKey(nonce: nonce, password: credentials.password)
            setCipher(.aes(key: key))
        }

        // Modern login.
        let userHash = BcMD5.reolinkHash(credentials.username + nonce)
        let passHash = BcMD5.reolinkHash(credentials.password + nonce)
        let xml = BcXmlBody.loginUserAndNet(usernameHash: userHash, passwordHash: passHash)

        let modernMsgNum = nextMessageNumber()
        let modernHeader = BcHeader(
            msgID: BcMessageID.login,
            bodyLength: 0,                                          // overwritten in BcMessage.encode
            channelID: 0,
            streamType: 0,
            msgNum: modernMsgNum,
            responseCode: 0,
            msgClass: BcConstants.classModernWithOffset,
            payloadOffset: 0
        )
        let modernLogin = BcMessage(header: modernHeader, body: xml)
        log.debug("Sending modern login msgNum=\(modernMsgNum) bodyBytes=\(xml.count)")
        let modernReply = try await sendAndAwait(modernLogin, timeout: 12, stage: "modern-login")
        log.info("Got modern login reply: code=\(modernReply.header.responseCode) bodyLen=\(modernReply.header.bodyLength)")

        guard modernReply.header.responseCode == 200 else {
            throw BaichuanError.loginFailed(reason: "code=\(modernReply.header.responseCode)")
        }

        // Try to extract a deviceName from the DeviceInfo reply for caller info.
        let replyXML = String(data: modernReply.body, encoding: .utf8) ?? ""
        let deviceName = BcXmlBody.firstTagContent(in: replyXML, tag: "name") ?? ""
        log.info("Baichuan login OK device=\(deviceName, privacy: .public)")

        // Sanity probe: send a simple no-body command (Version, msg_id=80)
        // AS the first AES-encoded outbound message. If this fails, we know
        // outbound AES encryption is producing ciphertext the camera can't
        // decrypt — and findAlarmVideo (~600 byte body) has no hope.
        await runAESSanityProbe()

        return deviceName
    }

    private func runAESSanityProbe() async {
        let header = BcHeader(
            msgID: BcMessageID.version,
            bodyLength: 0,
            channelID: 0,
            streamType: 0,
            msgNum: nextMessageNumber(),
            responseCode: 0,
            msgClass: BcConstants.classModernWithOffset,
            payloadOffset: 0
        )
        let probe = BcMessage(header: header, body: Data())
        do {
            let reply = try await sendAndAwait(probe, timeout: 4, stage: "version-probe")
            log.info("AES sanity probe (msg_id=80 Version) reply code=\(reply.header.responseCode) bodyLen=\(reply.body.count)")
        } catch {
            log.error("AES sanity probe failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func looksLikeXML(_ data: Data) -> Bool {
        let prefix = data.prefix(5)
        return prefix == Data("<?xml".utf8)
    }
}
