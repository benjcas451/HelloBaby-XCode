import Foundation
import Security

/// Das Client-Zertifikat ließ sich nicht verwenden.
struct ClientIdentityError: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

/// Baut aus den PEM-Dateien (client.crt / client.key)
/// eine `SecIdentity`, die URLSession beim TLS-Handshake anbieten kann.
///
/// URLSession akzeptiert nur eine Identity aus dem Keychain, deshalb werden
/// Zertifikat und Schlüssel dort abgelegt und anschließend wieder als Paar
/// herausgesucht.
enum ClientIdentity {

  private static let certificateLabel = "HelloBaby Client"
  private static let keyTag = Data("ch.tschir.hellobaby.clientkey".utf8)

  static func make(certPEM: Data, keyPEM: Data) throws -> SecIdentity {
    let certificate = try makeCertificate(from: certPEM)
    let key = try makePrivateKey(from: keyPEM)
    try store(certificate: certificate, key: key)
    return try identity(matching: certificate)
  }

  // MARK: - Bausteine

  private static func makeCertificate(from pem: Data) throws -> SecCertificate {
    guard let der = PEM.blocks(in: pem).first(where: { $0.type.contains("CERTIFICATE") })?.der
    else {
      throw ClientIdentityError(message: "client.crt enthält kein PEM-Zertifikat.")
    }
    guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
      throw ClientIdentityError(message: "client.crt ist kein gültiges X.509-Zertifikat.")
    }
    return certificate
  }

  private static func makePrivateKey(from pem: Data) throws -> SecKey {
    guard let block = PEM.blocks(in: pem).first(where: { $0.type.contains("PRIVATE KEY") }) else {
      throw ClientIdentityError(message: "client.key enthält keinen PEM-Schlüssel.")
    }
    if block.type.contains("ENCRYPTED") {
      throw ClientIdentityError(
        message: "client.key ist mit einer Passphrase geschützt. Bitte einen "
          + "Schlüssel ohne Passphrase hinterlegen.")
    }

    let pkcs1: Data
    switch block.type {
    case "RSA PRIVATE KEY":
      pkcs1 = block.der
    case "PRIVATE KEY":
      pkcs1 = try PEM.rsaPKCS1(fromPKCS8: block.der)
    default:
      throw ClientIdentityError(
        message: "Es werden nur RSA-Client-Zertifikate unterstützt "
          + "(\(block.type)).")
    }

    var error: Unmanaged<CFError>?
    let attributes: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
      kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
    ]
    guard let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, &error)
    else {
      let grund = (error?.takeRetainedValue()).map { String(describing: $0) } ?? "unbekannt"
      throw ClientIdentityError(message: "client.key konnte nicht gelesen werden: \(grund)")
    }
    return key
  }

  private static func store(certificate: SecCertificate, key: SecKey) throws {
    // Frühere Einträge entfernen, damit ein erneuter Import sauber greift.
    SecItemDelete(
      [
        kSecClass as String: kSecClassCertificate,
        kSecAttrLabel as String: certificateLabel,
      ] as CFDictionary)
    SecItemDelete(
      [
        kSecClass as String: kSecClassKey,
        kSecAttrApplicationTag as String: keyTag,
      ] as CFDictionary)

    let certStatus = SecItemAdd(
      [
        kSecClass as String: kSecClassCertificate,
        kSecValueRef as String: certificate,
        kSecAttrLabel as String: certificateLabel,
      ] as CFDictionary, nil)
    guard certStatus == errSecSuccess || certStatus == errSecDuplicateItem else {
      throw ClientIdentityError(
        message: "Zertifikat konnte nicht im Schlüsselbund abgelegt werden (\(certStatus)).")
    }

    let keyStatus = SecItemAdd(
      [
        kSecClass as String: kSecClassKey,
        kSecValueRef as String: key,
        kSecAttrApplicationTag as String: keyTag,
      ] as CFDictionary, nil)
    guard keyStatus == errSecSuccess || keyStatus == errSecDuplicateItem else {
      throw ClientIdentityError(
        message: "Schlüssel konnte nicht im Schlüsselbund abgelegt werden (\(keyStatus)).")
    }
  }

  /// Sucht die Identity, deren Zertifikat exakt dem importierten entspricht.
  private static func identity(matching certificate: SecCertificate) throws -> SecIdentity {
    let query: [String: Any] = [
      kSecClass as String: kSecClassIdentity,
      kSecMatchLimit as String: kSecMatchLimitAll,
      kSecReturnRef as String: true,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let identities = result as? [SecIdentity] else {
      throw ClientIdentityError(
        message: "Im Schlüsselbund wurde keine passende Identität gefunden (\(status)).")
    }

    let wanted = SecCertificateCopyData(certificate) as Data
    for candidate in identities {
      var certificateRef: SecCertificate?
      guard
        SecIdentityCopyCertificate(candidate, &certificateRef) == errSecSuccess,
        let certificateRef,
        (SecCertificateCopyData(certificateRef) as Data) == wanted
      else { continue }
      return candidate
    }
    throw ClientIdentityError(
      message: "Zertifikat und Schlüssel passen nicht zusammen.")
  }
}

// MARK: - PEM/DER

enum PEM {

  struct Block {
    let type: String
    let der: Data
  }

  /// Liest alle `-----BEGIN <typ>-----`-Blöcke einer PEM-Datei.
  static func blocks(in data: Data) -> [Block] {
    guard let text = String(data: data, encoding: .utf8)
      ?? String(data: data, encoding: .isoLatin1)
    else { return [] }

    var blocks: [Block] = []
    var type: String?
    var base64 = ""
    for line in text.split(whereSeparator: \.isNewline) {
      let zeile = line.trimmingCharacters(in: .whitespaces)
      if zeile.hasPrefix("-----BEGIN ") {
        type = zeile
          .replacingOccurrences(of: "-----BEGIN ", with: "")
          .replacingOccurrences(of: "-----", with: "")
          .trimmingCharacters(in: .whitespaces)
        base64 = ""
      } else if zeile.hasPrefix("-----END ") {
        if let type, let der = Data(base64Encoded: base64) {
          blocks.append(Block(type: type, der: der))
        }
        type = nil
        base64 = ""
      } else if type != nil {
        base64 += zeile
      }
    }
    return blocks
  }

  /// Schält aus einem PKCS#8-Schlüssel den PKCS#1-Teil heraus, weil
  /// `SecKeyCreateWithData` für RSA genau dieses Format erwartet.
  static func rsaPKCS1(fromPKCS8 der: Data) throws -> Data {
    let rsaEncryption: [UInt8] = [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]
    let bytes = [UInt8](der)

    var index = 0
    guard let outer = readTLV(bytes, &index), outer.tag == 0x30 else {
      throw ClientIdentityError(message: "client.key hat keine gültige PKCS#8-Struktur.")
    }

    var inner = 0
    guard let version = readTLV(outer.value, &inner), version.tag == 0x02,
      let algorithm = readTLV(outer.value, &inner), algorithm.tag == 0x30
    else {
      throw ClientIdentityError(message: "client.key hat keine gültige PKCS#8-Struktur.")
    }

    var algorithmIndex = 0
    guard let oid = readTLV(algorithm.value, &algorithmIndex), oid.tag == 0x06 else {
      throw ClientIdentityError(message: "client.key nennt kein Schlüsselverfahren.")
    }
    guard oid.value == rsaEncryption else {
      throw ClientIdentityError(
        message: "Es werden nur RSA-Client-Zertifikate unterstützt. "
          + "Bitte ein RSA-Schlüsselpaar verwenden.")
    }

    guard let key = readTLV(outer.value, &inner), key.tag == 0x04 else {
      throw ClientIdentityError(message: "client.key enthält keinen Schlüssel.")
    }
    return Data(key.value)
  }

  /// Liest ein einzelnes DER-TLV ab `index` und schiebt `index` dahinter.
  private static func readTLV(
    _ bytes: [UInt8], _ index: inout Int
  ) -> (tag: UInt8, value: [UInt8])? {
    guard index < bytes.count else { return nil }
    let tag = bytes[index]
    index += 1

    guard index < bytes.count else { return nil }
    var length = Int(bytes[index])
    index += 1

    if length & 0x80 != 0 {
      let count = length & 0x7F
      guard count > 0, count <= 4, index + count <= bytes.count else { return nil }
      length = 0
      for _ in 0..<count {
        length = (length << 8) | Int(bytes[index])
        index += 1
      }
    }

    guard length >= 0, index + length <= bytes.count else { return nil }
    let value = Array(bytes[index..<(index + length)])
    index += length
    return (tag, value)
  }
}
