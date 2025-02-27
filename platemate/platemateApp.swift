//
//  platemateApp.swift
//  platemate
//
//  Created by Raj Jagirdar on 2/27/25.
//

import SwiftUI

@main
struct platemateApp: App {
    let persistenceController = PersistenceController.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.managedObjectContext, persistenceController.container.viewContext)
        }
    }
}
