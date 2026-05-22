import Foundation
import HealthKit

struct FlatSample: Encodable {
    let type: String
    let uuid: String
    let start: Date
    let end: Date
    let value: Double?
    let unit: String?
    let source: String
    let deviceName: String?
    let deviceModel: String?
    let deviceManufacturer: String?
    let deviceHardwareVersion: String?
    let deviceSoftwareVersion: String?
    let metadata: [String: String]

    init?(from sample: HKSample, exportType: HealthKitExportType) {
        guard let quantitySample = sample as? HKQuantitySample else { return nil }

        let hkUnit = exportType.defaultUnit
        self.type = exportType.rawValue
        self.uuid = sample.uuid.uuidString
        self.start = sample.startDate
        self.end = sample.endDate
        self.value = quantitySample.quantity.doubleValue(for: hkUnit)
        self.unit = hkUnit.unitString
        self.source = sample.sourceRevision.source.name
        self.deviceName = sample.device?.name
        self.deviceModel = sample.device?.model
        self.deviceManufacturer = sample.device?.manufacturer
        self.deviceHardwareVersion = sample.device?.hardwareVersion
        self.deviceSoftwareVersion = sample.device?.softwareVersion

        var meta: [String: String] = [:]
        if let rawMeta = sample.metadata {
            for (key, val) in rawMeta {
                if let str = val as? String {
                    meta[key] = str
                } else if let num = val as? NSNumber {
                    meta[key] = num.stringValue
                }
                // non-string, non-number values dropped per API contract
            }
        }
        self.metadata = meta
    }
}

struct HealthBatchPayload: Encodable {
    let batchIndex: Int
    let samples: [FlatSample]
}
