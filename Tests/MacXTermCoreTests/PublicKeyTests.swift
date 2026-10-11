import Darwin
import Foundation
import Testing

@testable import MacXTermCore

@Suite("本机公钥") struct PublicKeyTests {
    // Public-only OpenSSH fixtures; fingerprints independently checked with ssh-keygen -lf -E sha256.
    private let ed25519 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGaj+JEju4rENgYxqQ4QIDMBu/3jOhgiREaec2x03nhP"
    private let rsa =
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDbsqyvsPiAkIPCY3pGZ1y9StCSB1WZOkab+1C89doiiD0vVl+lzwFoZJIGL5lLhH6OzKFhvsMCNvoBWW6Vtf0OYvI/S/PIP7YEzcPCs5zytaryVgZW89o2EsUnKgvrgpIzKmPHSWE/tCXp18bFtguMR5J1xQkgbULMqg0hJe5QMEOAfcW4mplHHbdvFLSuQA17IC5gSsVrfaZhdMG1CJWl/iujtzTBOuZzuf+3Ld8ltq05aSG6uce9lP4767rBRu55Y0mrwvAIb0GabplL/4f+gXRhm/KS5AZKPOQlCOUqUPPmRSp5+5dKbKU579pyj7bmAg+AIBYoDxiEtVeZD2eP"
    private let file = URL(fileURLWithPath: "/test/id_ed25519.pub")

    @Test func fingerprintMatchesOpenSSHAndCopyPreservesOneLine() throws {
        let key = try LocalPublicKey.parse(Data(("# comment\r\n  " + ed25519 + "\t我的 Mac\r\n").utf8), file: file)
        #expect(key.algorithm == "ssh-ed25519")
        #expect(key.comment == "我的 Mac")
        #expect(key.filename == "id_ed25519.pub")
        #expect(key.fingerprint == "SHA256:0b+BQbWELn1zXqD5beCevvNSIxmCn/44arT3Uvg2pIs")
        #expect(key.clipboardText == ed25519 + " 我的 Mac\n")
        #expect(key.clipboardText.split(separator: "\n").count == 1)
        let rsaKey = try LocalPublicKey.parse(Data(rsa.utf8), file: file)
        #expect(rsaKey.fingerprint == "SHA256:WqbdS5Rer8vjr261OEwG1afQhs9Prp/7/dfYiYbYaJc")
        #expect(rsaKey.comment.isEmpty)
    }

    @Test(arguments: ["OPENSSH", "RSA", "EC", "ENCRYPTED"])
    func refusesPrivateKeyArmor(_ kind: String) {
        let data = Data("-----BEGIN \(kind) PRIVATE KEY-----\nnot-a-public-key".utf8)
        #expect(throws: MacXError.self) { try LocalPublicKey.parse(data, file: file) }
    }

    @Test func refusesMultipleKeysOptionsAndControlCharacters() {
        for text in [ed25519 + "\n" + ed25519, "command=\"run\" " + ed25519, ed25519 + "\0suffix", "", "# no key"] {
            #expect(throws: MacXError.self) { try LocalPublicKey.parse(Data(text.utf8), file: file) }
        }
    }

    @Test func refusesMismatchedTruncatedAndTrailingWireData() throws {
        let base64 = try #require(ed25519.split(separator: " ").last)
        let blob = try #require(Data(base64Encoded: String(base64)))
        let invalid = [
            "ssh-rsa " + base64,
            "ssh-ed25519 " + blob.dropLast().base64EncodedString(),
            "ssh-ed25519 " + (blob + Data([0])).base64EncodedString(),
            "ssh-ed25519 " + Data([255, 255, 255, 255]).base64EncodedString(),
            "ssh-ed25519 not-base64",
        ]
        for text in invalid {
            #expect(throws: MacXError.self) { try LocalPublicKey.parse(Data(text.utf8), file: file) }
        }
    }

    @Test(arguments: ["nistp256", "nistp384", "nistp521"])
    func acceptsEllipticCurveWireFormats(_ curve: String) throws {
        let length = ["nistp256": 65, "nistp384": 97, "nistp521": 133][curve]!
        let algorithm = "ecdsa-sha2-" + curve
        let fields = [
            Data(algorithm.utf8), Data(curve.utf8), Data([4] + Array(repeating: UInt8(1), count: length - 1)),
        ]
        let key = try parseWire(algorithm, fields)
        #expect(key.algorithm == algorithm)
        #expect(throws: MacXError.self) { try parseWire(algorithm, [fields[0], Data("other-curve".utf8), fields[2]]) }
    }

    @Test func acceptsSecurityKeyWireFormatsAndRequiresApplication() throws {
        let ed = "sk-ssh-ed25519@openssh.com"
        let ec = "sk-ecdsa-sha2-nistp256@openssh.com"
        let application = Data("ssh:".utf8)
        let edFields = [Data(ed.utf8), Data(repeating: 1, count: 32)]
        let ecFields = [Data(ec.utf8), Data("nistp256".utf8), Data([4] + Array(repeating: UInt8(1), count: 64))]
        #expect(try parseWire(ed, edFields + [application]).algorithm == ed)
        #expect(try parseWire(ec, ecFields + [application]).algorithm == ec)
        #expect(throws: MacXError.self) { try parseWire(ed, edFields) }
        #expect(throws: MacXError.self) { try parseWire(ec, ecFields + [Data()]) }
    }

    @Test func scanReadsOnlyImmediatePublicFilesAndReportsInvalidOnes() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(ed25519.utf8).write(to: root.appendingPathComponent("id_ed25519.pub"))
        try Data(rsa.utf8).write(to: root.appendingPathComponent("id_rsa.pub"))
        try Data("private data placeholder".utf8).write(to: root.appendingPathComponent("id_ed25519"))
        try Data("invalid public key".utf8).write(to: root.appendingPathComponent("invalid.pub"))
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(ed25519.utf8).write(to: nested.appendingPathComponent("nested.pub"))
        let scan = try LocalPublicKeyReader.scan(root)
        #expect(scan.keys.map(\.filename) == ["id_ed25519.pub", "id_rsa.pub"])
        #expect(scan.issues.count == 1)
        #expect(scan.issues.first?.hasPrefix("invalid.pub：") == true)
        #expect(throws: MacXError.self) { try LocalPublicKeyReader.read(root.appendingPathComponent("id_ed25519")) }
    }

    @Test func refusesSymlinksDirectoriesAndFIFOsWithoutBlocking() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let regular = root.appendingPathComponent("regular.pub")
        try Data(ed25519.utf8).write(to: regular)
        let link = root.appendingPathComponent("link.pub")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: regular)
        let directory = root.appendingPathComponent("directory.pub")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fifo = root.appendingPathComponent("fifo.pub")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        for url in [link, directory, fifo] {
            #expect(throws: MacXError.self) { try LocalPublicKeyReader.read(url) }
        }
    }

    @Test func boundsFileSizeAndRejectsNonUTF8() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let oversized = Data(repeating: 65, count: LocalPublicKeyReader.maximumBytes + 1)
        let url = root.appendingPathComponent("large.pub")
        try oversized.write(to: url)
        #expect(throws: MacXError.self) { try LocalPublicKeyReader.read(url) }
        #expect(throws: MacXError.self) { try LocalPublicKey.parse(oversized, file: file) }
        #expect(throws: MacXError.self) { try LocalPublicKey.parse(Data([255, 254]), file: file) }
    }

    private func parseWire(_ algorithm: String, _ fields: [Data]) throws -> LocalPublicKey {
        var blob = Data()
        for field in fields {
            let length = UInt32(field.count)
            blob.append(contentsOf: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: length >> $0) })
            blob.append(field)
        }
        return try LocalPublicKey.parse(Data((algorithm + " " + blob.base64EncodedString()).utf8), file: file)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
