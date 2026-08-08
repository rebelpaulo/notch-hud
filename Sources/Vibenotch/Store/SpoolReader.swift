import Foundation

struct SpoolReader: Sendable {
    func read(at fileURL: URL) -> Session? {
        guard
            let data = try? Data(contentsOf: fileURL),
            let envelope = try? JSONDecoder().decode(SessionEnvelope.self, from: data),
            let updatedAt = parseISO8601(envelope.updated)
        else {
            return nil
        }

        return Session(envelope: envelope, updatedAt: updatedAt)
    }

    private func parseISO8601(_ value: String) -> Date? {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}
