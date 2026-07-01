//
//  ThermalSample.swift
//  ThermalReporter
//
//  Created by Rahul and Vishal Ramamurthy on 3/29/26.
//

import Foundation
import SwiftData

@Model
final class ThermalSample {
    var timestamp: Int
    var thermalState: Int
    var batteryLevel: Float
    var isCharging: Bool
    var lowPowerMode: Bool
    var brightness: Float

    init(
        timestamp: Int,
        thermalState: Int,
        batteryLevel: Float,
        isCharging: Bool,
        lowPowerMode: Bool,
        brightness: Float
    ) {
        self.timestamp = timestamp
        self.thermalState = thermalState
        self.batteryLevel = batteryLevel
        self.isCharging = isCharging
        self.lowPowerMode = lowPowerMode
        self.brightness = brightness
    }
}
