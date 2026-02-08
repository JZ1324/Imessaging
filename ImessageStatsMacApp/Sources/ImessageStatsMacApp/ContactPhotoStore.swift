import Foundation
import Contacts
import ContactsUI
import AppKit
import CryptoKit

final class ContactPhotoStore {
    static let shared = ContactPhotoStore()
    static let accessDeniedNotification = Notification.Name("ContactPhotoStoreAccessDenied")
    private static var hasNotifiedAccessDenied = false

    private let cache = NSCache<NSString, NSImage>()
    private let store = CNContactStore()
    private let queue = DispatchQueue(label: "ContactPhotoStore", qos: .userInitiated)
    private var loaded = false
    private var imageByHandle: [String: NSImage] = [:]
    private var imageByName: [String: NSImage] = [:]
    private var contactByHandle: [String: CNContact] = [:]
    private var contactByName: [String: CNContact] = [:]

    private init() {
        cache.countLimit = 300
    }

    func fetchImages(handles: [String], maxCount: Int, fallbackName: String?, completion: @escaping ([NSImage]) -> Void) {
        queue.async {
            guard self.ensureAccess() else {
                DispatchQueue.main.async { completion([]) }
                return
            }

            if !self.loaded {
                self.loadContacts()
            }

            var results: [NSImage] = []
            for handle in handles {
                for variant in self.normalizeHandle(handle) {
                    if let cached = self.cache.object(forKey: variant as NSString) {
                        results.append(cached)
                        break
                    }
                    if let image = self.imageByHandle[variant] {
                        self.cache.setObject(image, forKey: variant as NSString)
                        results.append(image)
                        break
                    }
                }
                if results.count >= maxCount { break }
            }

            if results.isEmpty, let name = fallbackName, !name.isEmpty {
                let key = name.lowercased()
                if let cached = self.cache.object(forKey: key as NSString) {
                    results.append(cached)
                } else if let image = self.imageByName[key] {
                    self.cache.setObject(image, forKey: key as NSString)
                    results.append(image)
                }
            }

            DispatchQueue.main.async {
                completion(results)
            }
        }
    }

    func fetchContact(handles: [String], fallbackName: String?, completion: @escaping (CNContact?) -> Void) {
        queue.async {
            guard self.ensureAccess() else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            if !self.loaded {
                self.loadContacts()
            }

            var match: CNContact?
            for handle in handles {
                for variant in self.normalizeHandle(handle) {
                    if let contact = self.contactByHandle[variant] {
                        match = contact
                        break
                    }
                }
                if match != nil { break }
            }

            if match == nil, let name = fallbackName, !name.isEmpty {
                match = self.contactByName[name.lowercased()]
            }

            DispatchQueue.main.async {
                completion(match)
            }
        }
    }

    func fetchDisplayName(handles: [String], fallbackName: String?, completion: @escaping (String?) -> Void) {
        queue.async {
            guard self.ensureAccess() else {
                DispatchQueue.main.async { completion(nil) }
                return
            }

            if !self.loaded {
                self.loadContacts()
            }

            var match: String?
            for handle in handles {
                for variant in self.normalizeHandle(handle) {
                    if let contact = self.contactByHandle[variant] {
                        let name = self.displayName(from: contact)
                        if !name.isEmpty {
                            match = name
                            break
                        }
                    }
                }
                if match != nil { break }
            }

            if match == nil, let fallbackName, !fallbackName.isEmpty {
                if let contact = self.contactByName[fallbackName.lowercased()] {
                    let name = self.displayName(from: contact)
                    if !name.isEmpty {
                        match = name
                    }
                }
            }

            DispatchQueue.main.async {
                completion(match)
            }
        }
    }

    func requestAccess(completion: @escaping (Bool) -> Void) {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized:
            completion(true)
        case .notDetermined:
            store.requestAccess(for: .contacts) { granted, _ in
                DispatchQueue.main.async {
                    completion(granted)
                }
            }
        default:
            completion(false)
        }
    }

    struct ExportedContactPoint: Hashable {
        let contactName: String
        let handle: String
        let handleType: String
        let handleNormalized: String
        let handleHash: String
    }

    func exportContactPoints(completion: @escaping ([ExportedContactPoint]) -> Void) {
        queue.async {
            guard self.ensureAccess() else {
                DispatchQueue.main.async { completion([]) }
                return
            }

            let keys: [CNKeyDescriptor] = [
                CNContactGivenNameKey as CNKeyDescriptor,
                CNContactFamilyNameKey as CNKeyDescriptor,
                CNContactOrganizationNameKey as CNKeyDescriptor,
                CNContactPhoneNumbersKey as CNKeyDescriptor,
                CNContactEmailAddressesKey as CNKeyDescriptor
            ]
            let request = CNContactFetchRequest(keysToFetch: keys)

            var results: [ExportedContactPoint] = []
            var seen: Set<String> = []

            do {
                try self.store.enumerateContacts(with: request) { contact, _ in
                    let name = self.displayName(from: contact)

                    for phone in contact.phoneNumbers {
                        let raw = phone.value.stringValue
                        guard let normalized = self.normalizeContactHandle(raw, typeHint: "phone") else { continue }
                        let hash = self.hashHandle(normalized, type: "phone")
                        if seen.insert(hash).inserted {
                            results.append(ExportedContactPoint(
                                contactName: name,
                                handle: raw,
                                handleType: "phone",
                                handleNormalized: normalized,
                                handleHash: hash
                            ))
                        }
                    }

                    for email in contact.emailAddresses {
                        let raw = (email.value as String)
                        guard let normalized = self.normalizeContactHandle(raw, typeHint: "email") else { continue }
                        let hash = self.hashHandle(normalized, type: "email")
                        if seen.insert(hash).inserted {
                            results.append(ExportedContactPoint(
                                contactName: name,
                                handle: raw,
                                handleType: "email",
                                handleNormalized: normalized,
                                handleHash: hash
                            ))
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async { completion([]) }
                return
            }

            DispatchQueue.main.async {
                completion(results)
            }
        }
    }

    private func ensureAccess() -> Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            let semaphore = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                self.store.requestAccess(for: .contacts) { _, _ in
                    semaphore.signal()
                }
            }
            _ = semaphore.wait(timeout: .now() + 8)
            let authorized = CNContactStore.authorizationStatus(for: .contacts) == .authorized
            if !authorized {
                notifyAccessDenied()
            }
            return authorized
        default:
            notifyAccessDenied()
            return false
        }
    }

    private func notifyAccessDenied() {
        guard !Self.hasNotifiedAccessDenied else { return }
        Self.hasNotifiedAccessDenied = true
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.accessDeniedNotification, object: nil)
        }
    }

    private func loadContacts() {
        let keys: [CNKeyDescriptor] = [
            CNContactViewController.descriptorForRequiredKeys(),
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor,
            CNContactImageDataKey as CNKeyDescriptor
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)

        do {
            try store.enumerateContacts(with: request) { contact, _ in
                guard let image = self.imageFromContact(contact) else { return }
                let name = displayName(from: contact)
                if !name.isEmpty {
                    let key = name.lowercased()
                    if self.imageByName[key] == nil {
                        self.imageByName[key] = image
                    }
                    if self.contactByName[key] == nil {
                        self.contactByName[key] = contact
                    }
                }

                for phone in contact.phoneNumbers {
                    let value = phone.value.stringValue
                    for variant in self.normalizeHandle(value) {
                        if self.imageByHandle[variant] == nil {
                            self.imageByHandle[variant] = image
                        }
                        if self.contactByHandle[variant] == nil {
                            self.contactByHandle[variant] = contact
                        }
                    }
                }
                for email in contact.emailAddresses {
                    let value = (email.value as String)
                    for variant in self.normalizeHandle(value) {
                        if self.imageByHandle[variant] == nil {
                            self.imageByHandle[variant] = image
                        }
                        if self.contactByHandle[variant] == nil {
                            self.contactByHandle[variant] = contact
                        }
                    }
                }
            }
        } catch {
            return
        }

        loaded = true
    }

    private func imageFromContact(_ contact: CNContact) -> NSImage? {
        if let data = contact.thumbnailImageData ?? contact.imageData {
            return NSImage(data: data)
        }
        return nil
    }

    private func displayName(from contact: CNContact) -> String {
        let combined = [contact.givenName, contact.familyName]
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        if !combined.isEmpty {
            return combined
        }
        if !contact.organizationName.isEmpty {
            return contact.organizationName
        }
        return ""
    }

    private func normalizeHandle(_ handle: String) -> [String] {
        var trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("imessage;") {
            trimmed = String(trimmed.dropFirst("iMessage;".count))
        } else if lower.hasPrefix("sms;") {
            trimmed = String(trimmed.dropFirst("SMS;".count))
        } else if lower.hasPrefix("mailto:") {
            trimmed = String(trimmed.dropFirst("mailto:".count))
        } else if lower.hasPrefix("tel:") {
            trimmed = String(trimmed.dropFirst("tel:".count))
        } else if lower.hasPrefix("p:") || lower.hasPrefix("e:") {
            trimmed = String(trimmed.dropFirst(2))
        }

        let cleaned = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return [] }
        if cleaned.contains("@") {
            return [cleaned.lowercased()]
        }
        let digits = cleaned.filter { $0.isNumber }
        if digits.isEmpty { return [cleaned] }
        if digits.count > 10 {
            return Array(Set([digits, String(digits.suffix(10))]))
        }
        return [digits]
    }

    private func normalizeContactHandle(_ handle: String, typeHint: String) -> String? {
        let cleaned = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return nil }

        if typeHint == "email" || cleaned.contains("@") {
            return cleaned.lowercased()
        }

        // Phone-ish: keep a leading '+' if it exists, otherwise digits only.
        let hasPlus = cleaned.first == "+"
        let digits = cleaned.filter { $0.isNumber }
        if digits.isEmpty { return nil }
        return hasPlus ? "+\(digits)" : digits
    }

    private func hashHandle(_ normalized: String, type: String) -> String {
        // Prefix with type to prevent collisions between email/phone.
        let input = "\(type):\(normalized.lowercased())"
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
