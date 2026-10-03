import Foundation
import Security

/// Minimal generic-password wrapper for the server password (login keychain).
public enum Keychain {
    public static let service = "de.daniele.JobHunter.server"

    public enum KeychainError: LocalizedError {
        case status(OSStatus)
        public var errorDescription: String? {
            if case .status(let s) = self {
                return "Schlüsselbund-Fehler \(s): " + ((SecCopyErrorMessageString(s, nil) as String?) ?? "")
            }
            return nil
        }
    }

    private static func baseQuery(account: String, service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public static func password(account: String, service: String = service) -> String? {
        var query = baseQuery(account: account, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    public static func setPassword(_ password: String, account: String, service: String = service) throws {
        let query = baseQuery(account: account, service: service)
        if password.isEmpty {
            try delete(account: account, service: service)
            return
        }
        let data = Data(password.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "JobHunter (job-hunter Server)"
            let s = SecItemAdd(add as CFDictionary, nil)
            guard s == errSecSuccess else { throw KeychainError.status(s) }
        } else if status != errSecSuccess {
            throw KeychainError.status(status)
        }
    }

    public static func delete(account: String, service: String = service) throws {
        let s = SecItemDelete(baseQuery(account: account, service: service) as CFDictionary)
        guard s == errSecSuccess || s == errSecItemNotFound else { throw KeychainError.status(s) }
    }
}
