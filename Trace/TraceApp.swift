//
//  TraceApp.swift
//  Trace
//
//  Created by Mohit Nalavadi on 16.04.25.
//

import SwiftUI

@main
struct TraceApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
