//
//  LoginItemController.swift
//  HermitFlow
//

import Foundation
import ServiceManagement

@MainActor
final class LoginItemController {
    var isEnabled: Bool {
        guard #available(macOS 13.0, *) else {
            return false
        }
        return SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ isEnabled: Bool) throws {
        guard #available(macOS 13.0, *) else {
            throw NSError(
                domain: "HermitFlow.LoginItemController",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Launch at login requires macOS 13.0 or newer."]
            )
        }

        if isEnabled {
            guard SMAppService.mainApp.status != .enabled else {
                return
            }
            try SMAppService.mainApp.register()
        } else {
            guard SMAppService.mainApp.status != .notRegistered else {
                return
            }
            try SMAppService.mainApp.unregister()
        }
    }
}
