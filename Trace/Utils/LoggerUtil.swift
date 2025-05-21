import Foundation
import os.log

/// Provides timestamped logging functionality
class LoggerUtil {
    private let logger: Logger
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale.current
        formatter.timeZone = TimeZone.current
        return formatter
    }()
    
    init(category: String) {
        logger = Logger(subsystem: "com.trace", category: category)
    }
    
    private func timestamp() -> String {
        "[\(Self.dateFormatter.string(from: Date()))]"
    }
    
    func info(_ message: String) {
        logger.info("\(self.timestamp()) \(message)")
    }
    
    func error(_ message: String) {
        logger.error("\(self.timestamp()) ❌ \(message)")
    }
    
    func warning(_ message: String) {
        logger.warning("\(self.timestamp()) ⚠️ \(message)")
    }
    
    func debug(_ message: String) {
        logger.debug("\(self.timestamp()) 🔍 \(message)")
    }
} 
 