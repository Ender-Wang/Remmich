//
//  RemmichApp.swift
//  Remmich
//
//  Created by Ender Wang on 9/25/26.
//

import SwiftUI

@main
struct RemmichApp: App {
    @UIApplicationDelegateAdaptor(RemmichAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
