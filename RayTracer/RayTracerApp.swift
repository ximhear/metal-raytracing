//
//  RayTracerApp.swift
//

import SwiftUI

@main
struct RayTracerApp: App {
    init() {
        #if os(macOS)
        Snapshot.runIfRequested()   // --snapshot 이면 여기서 PNG 쓰고 종료
        #endif
    }

    var body: some Scene {
        #if os(macOS)
        WindowGroup {
            ContentView().frame(minWidth: 640, minHeight: 400)
        }
        .defaultSize(width: 1024, height: 640)
        #else
        WindowGroup { ContentView() }
        #endif
    }
}
