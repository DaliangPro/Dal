enum CredentialDefaultValues {
    static func values(from fields: [CredentialField]) -> [String: String] {
        var values: [String: String] = [:]
        for field in fields where !field.defaultValue.isEmpty {
            values[field.key] = field.defaultValue
        }
        return values
    }
}
