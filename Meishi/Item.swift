//
//  Item.swift
//  Meishi
//
//  Created by Jin Kishimoto on 2026/03/24.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
