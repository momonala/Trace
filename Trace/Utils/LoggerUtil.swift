import Foundation
import os.log

class LoggerUtil {
    private let logger: Logger
    private let category: String

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    private var timestamp: String {
        "[\(Self.formatter.string(from: Date()))]"
    }

    init(category: String) {
        self.category = category
        logger = Logger(subsystem: "com.trace", category: category)
    }

    func debug(_ message: String) {
        logger.debug("\(self.timestamp) 🔍 [\(self.category)] \(message)")
    }

    func info(_ message: String) {
        logger.info("\(self.timestamp) ✅ [\(self.category)] \(message)")
    }

    func warning(_ message: String) {
        logger.warning("\(self.timestamp) ⚠️ [\(self.category)] \(message)")
    }

    func error(_ message: String) {
        logger.error("\(self.timestamp) 🚨 [\(self.category)] \(message)")
    }
}
