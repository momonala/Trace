//
//  TraceWidgetsBundle.swift
//  TraceWidgets
//
//  Created by Mohit Nalavadi on 20.05.25.
//

import WidgetKit
import SwiftUI

@main
struct TraceWidgetsBundle: WidgetBundle {
    var body: some Widget {
        TraceWidgets()
        TraceWidgetsLiveActivity()
    }
}
