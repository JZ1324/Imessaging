import Foundation
import Contacts

final class ContactsResolver {
    private var nameByHandle: [String: String] = [:]
    private var idByHandle: [String: String] = [:]
    private var idByName: [String: String] = [:]

    init() {
        loadContacts()
    }

    func displayName(for handle: String) -> String? {
        for variant in normalizeVariants(handle) {
            if let name = nameByHandle[variant] {
                return name
            }
        }
        return nameByHandle[handle.lowercased()]
    }

    func contactIdentifier(for handle: String) -> String? {
        for variant in normalizeVariants(handle) {
            if let id = idByHandle[variant] {
                return id
            }
        }
        return idByHandle[handle.lowercased()]
    }

    func contactIdentifier(forName name: String) -> String? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key.isEmpty { return nil }
        return idByName[key]
    }

    private func loadContacts() {
        let store = CNContactStore()
        let status = CNContactStore.authorizationStatus(for: .contacts)

        switch status {
        case .authorized:
            fetchContacts(from: store)
        case .notDetermined:
            store.requestAccess(for: .contacts) { granted, _ in
                if granted {
                    self.fetchContacts(from: store)
                }
            }
        default:
            return
        }
    }

    private func fetchContacts(from store: CNContactStore) {
        let keys: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor
        ]

        let request = CNContactFetchRequest(keysToFetch: keys)
        try? store.enumerateContacts(with: request) { contact, _ in
            let name = ContactsResolver.displayName(from: contact)
            guard !name.isEmpty else { return }
            let contactId = contact.identifier
            let nameKey = name.lowercased()
            if !nameKey.isEmpty, self.idByName[nameKey] == nil {
                self.idByName[nameKey] = contactId
            }

            for phone in contact.phoneNumbers {
                let value = phone.value.stringValue
                for variant in self.normalizeVariants(value) {
                    if !variant.isEmpty, self.nameByHandle[variant] == nil {
                        self.nameByHandle[variant] = name
                    }
                    if !variant.isEmpty, self.idByHandle[variant] == nil {
                        self.idByHandle[variant] = contactId
                    }
                }
            }

            for email in contact.emailAddresses {
                let value = (email.value as String).lowercased()
                for variant in self.normalizeVariants(value) {
                    if !variant.isEmpty, self.nameByHandle[variant] == nil {
                        self.nameByHandle[variant] = name
                    }
                    if !variant.isEmpty, self.idByHandle[variant] == nil {
                        self.idByHandle[variant] = contactId
                    }
                }
            }
        }
    }

    private static func displayName(from contact: CNContact) -> String {
        let combined = [contact.givenName, contact.familyName].joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if !combined.isEmpty {
            return combined
        }
        if !contact.organizationName.isEmpty {
            return contact.organizationName
        }
        return ""
    }

    private func normalizeVariants(_ handle: String) -> [String] {
        let lower = handle.lowercased()
        if lower.contains("@") {
            return [lower]
        }
        let digits = lower.filter { $0.isNumber }
        if digits.isEmpty { return [] }
        if digits.count > 10 {
            return Array(Set([digits, String(digits.suffix(10))]))
        }
        return [digits]
    }
}
