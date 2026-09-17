import Foundation

/// Typed persistence on UserDefaults. Stores only facts the app observed,
/// never a claim that AirLift "is activated" without verification backing it.
struct PersistenceService {
    private let defaults: UserDefaults

    enum Key: String {
        case activationStateRaw = "airlift.activation.state"
        case activationLastVerified = "airlift.activation.lastVerified"
        case activationLastResult = "airlift.activation.lastResult"
        case filesViewMode = "files.viewMode"
        case filesShowHidden = "files.showHidden"
        case filesSortField = "files.sortField"
        case filesSortAscending = "files.sortAscending"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func string(forKey key: Key) -> String? {
        defaults.string(forKey: key.rawValue)
    }

    func setString(_ value: String?, forKey key: Key) {
        defaults.set(value, forKey: key.rawValue)
    }

    func date(forKey key: Key) -> Date? {
        defaults.object(forKey: key.rawValue) as? Date
    }

    func setDate(_ value: Date?, forKey key: Key) {
        defaults.set(value, forKey: key.rawValue)
    }

    func bool(forKey key: Key, default value: Bool) -> Bool {
        defaults.object(forKey: key.rawValue) as? Bool ?? value
    }

    func setBool(_ value: Bool, forKey key: Key) {
        defaults.set(value, forKey: key.rawValue)
    }

    func removeAllActivationData() {
        setString(nil, forKey: .activationStateRaw)
        setDate(nil, forKey: .activationLastVerified)
        setString(nil, forKey: .activationLastResult)
    }
}
