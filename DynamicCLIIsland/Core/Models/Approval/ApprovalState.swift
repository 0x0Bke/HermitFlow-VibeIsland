//
//  ApprovalState.swift
//  HermitFlow
//
//  Phase 5 approval subsystem model.
//

import Foundation

struct ApprovalState: Equatable {
    var currentRequest: ApprovalRequest?
    var resolvedRequestIDs: Set<String> = []
    var collapsedRequestID: String?
    var previewRequest: ApprovalRequest?
    var diagnostic: ApprovalDiagnostic?
    var lastPresentedRequestID: String?
}
