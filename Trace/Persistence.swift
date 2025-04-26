//
//  Persistence.swift
//  Trace
//
//  Created by Mohit Nalavadi on 16.04.25.
//

import CoreData

struct PersistenceController {
    static let shared = PersistenceController()
    private static let logger = LoggerUtil(category: "persistenceController")

    @MainActor
    static let preview: PersistenceController = {
        let result = PersistenceController(inMemory: true)
        return result
    }()

    let container: NSPersistentContainer

    init(inMemory: Bool = false) {
        container = NSPersistentContainer(name: "Trace")

        if inMemory {
            container.persistentStoreDescriptions.first!.url = URL(fileURLWithPath: "/dev/null")
        }

        container.loadPersistentStores { storeDescription, error in
            if let error = error as NSError? {
                // Log the error instead of crashing
                PersistenceController.logger.error("Failed to load persistent store: \(error.localizedDescription)")
                
                // Handle common error cases
                switch error.domain {
                case NSCocoaErrorDomain:
                    switch error.code {
                    case NSPersistentStoreIncompatibleVersionHashError:
                        PersistenceController.logger.error("Store model version hash mismatch")
                    case NSMigrationMissingSourceModelError:
                        PersistenceController.logger.error("Missing source model for migration")
                    case NSMigrationError:
                        PersistenceController.logger.error("Migration failed")
                    default:
                        PersistenceController.logger.error("Unhandled Cocoa error: \(error.code)")
                    }
                default:
                    PersistenceController.logger.error("Unhandled error domain: \(error.domain)")
                }
            }
        }
        
        // Enable automatic merging of changes from parent context
        container.viewContext.automaticallyMergesChangesFromParent = true
        
        // Configure view context to better handle background updates
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        container.viewContext.shouldDeleteInaccessibleFaults = true
    }

    /// Creates a new background context for performing operations off the main thread
    func newBackgroundContext() -> NSManagedObjectContext {
        let context = container.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        return context
    }
}
