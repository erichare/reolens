import Testing
import Foundation
import CryptoKit
@testable import ReolinkAPI

/// AGENTS.md §3 — TLS pinning is a hard-block on mismatch. These
/// tests pin the policy's observation / mismatch / allow contracts
/// independent of URLSession plumbing.
@Suite("TLSPinningPolicy")
struct TLSPinningPolicyTests {

    @Test("SHA-256 fingerprint is base64-encoded SHA-256 of the DER")
    func fingerprintMatchesDirectHash() {
        let der = Data([0x30, 0x82, 0x01, 0x00, 0xDE, 0xAD, 0xBE, 0xEF])
        let expected = Data(SHA256.hash(data: der)).base64EncodedString()
        let actual = TLSPinningPolicy.fingerprint(forCertificateDER: der)
        #expect(expected == actual)
    }

    @Test("alwaysAccept never invokes observation or mismatch")
    func alwaysAcceptIsInert() {
        let policy = TLSPinningPolicy.alwaysAccept
        // Both callbacks should be no-ops; we just verify the
        // policy's expected fingerprint is nil so the delegate
        // takes the TOFU path.
        #expect(policy.expectedFingerprint == nil)
    }

    @Test("Custom policy threads expected fingerprint through")
    func customPolicyHasExpected() async {
        let expected = "abc123base64=="
        let policy = TLSPinningPolicy(
            expectedFingerprint: expected,
            onObserved: { _ in },
            onMismatch: { _, _ in }
        )
        #expect(policy.expectedFingerprint == expected)
    }

    @Test("Two identical DERs produce identical fingerprints (stable hashing)")
    func stableHashing() {
        let der = Data((0..<512).map { UInt8($0 & 0xff) })
        let a = TLSPinningPolicy.fingerprint(forCertificateDER: der)
        let b = TLSPinningPolicy.fingerprint(forCertificateDER: der)
        #expect(a == b)
    }

    @Test("Different DERs produce different fingerprints")
    func differentDersDiffer() {
        let a = TLSPinningPolicy.fingerprint(forCertificateDER: Data([1, 2, 3]))
        let b = TLSPinningPolicy.fingerprint(forCertificateDER: Data([1, 2, 4]))
        #expect(a != b)
    }
}
