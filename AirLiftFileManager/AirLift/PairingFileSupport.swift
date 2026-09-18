import Foundation
import UniformTypeIdentifiers

/// UTI definitions for pairing files, verified against StikDebug's
/// `PairingFileStore.supportedContentTypes` (their import works on real
/// devices for both StikPair `.plist` exports and iloader
/// `.mobiledevicepairing` files). Generic types like `.item` are known to
/// gray out every row in the iOS document picker on some versions — these
/// explicit types do not.
enum PairingFileSupport {
    static let supportedContentTypes: [UTType] = [
        UTType(filenameExtension: "mobiledevicepairing", conformingTo: .data) ?? .data,
        UTType(filenameExtension: "mobiledevicepair", conformingTo: .data) ?? .data,
        .propertyList,
    ]

    /// Identifiers for CFBundleDocumentTypes so the app appears in share
    /// sheets ("Copy to AirLift File Manager") and Files "Open in…" — the
    /// import path that never touches the document picker.
    static var documentTypeIdentifiers: [String] {
        supportedContentTypes.map(\.identifier)
    }
}
