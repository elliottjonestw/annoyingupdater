import CryptoKit
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

// Release gate: reject a wrong CI key, wrong version, bad URL, or altered DMG.
let args = CommandLine.arguments
func fail(_ message: String) -> Never { fputs("Release verification failed: \(message)\n", stderr); exit(1) }
guard args.count == 5 else { fail("Expected appcast, DMG, Info.plist, version.") }
let feed = try XMLDocument(contentsOf: URL(fileURLWithPath: args[1]), options: [.nodeLoadExternalEntitiesNever])
let items = try feed.nodes(forXPath: "/rss/channel/item")
guard items.count == 1, let item = items.first as? XMLElement,
      let enclosure = item.elements(forName: "enclosure").first,
      item.elements(forName: "sparkle:version").first?.stringValue == args[4],
      item.elements(forName: "sparkle:shortVersionString").first?.stringValue == args[4],
      let encodedSignature = enclosure.attribute(forName: "sparkle:edSignature")?.stringValue,
      let signature = Data(base64Encoded: encodedSignature) else { fail("Invalid version or missing signature.") }
let expectedURL = "https://github.com/elliottjonestw/annoyingupdater/releases/download/v\(args[4])/upd8er-\(args[4])-universal.dmg"
guard enclosure.attribute(forName: "url")?.stringValue == expectedURL else { fail("Unexpected download URL.") }
let plistData = try Data(contentsOf: URL(fileURLWithPath: args[3]))
let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
guard let publicKey = plist?["SUPublicEDKey"] as? String, let keyData = Data(base64Encoded: publicKey) else { fail("No public key.") }
let archive = try Data(contentsOf: URL(fileURLWithPath: args[2]), options: .mappedIfSafe)
guard enclosure.attribute(forName: "length")?.stringValue == String(archive.count),
      try Curve25519.Signing.PublicKey(rawRepresentation: keyData).isValidSignature(signature, for: archive) else { fail("DMG signature does not match the app's public key.") }
print("Verified signed update \(args[4]) (\(archive.count) bytes).")
