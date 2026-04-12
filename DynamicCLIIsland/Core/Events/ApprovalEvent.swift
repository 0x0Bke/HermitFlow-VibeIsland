//
//  ApprovalEvent.swift
//  HermitFlow
//
//  Phase 4 event model.
//

import Foundation

struct ApprovalEvent: Hashable {
    let requestID: String
    let request: ApprovalRequest?
    let source: SessionOrigin
    let resolutionKind: ApprovalResolutionKind
    let createdAt: Date
    let diagnosticMessage: String?

    init(request: ApprovalRequest, diagnosticMessage: String? = nil) {
        requestID = request.id
        self.request = request
        source = request.source
        resolutionKind = request.resolutionKind
        createdAt = request.createdAt
        self.diagnosticMessage = diagnosticMessage
    }

    init(
        requestID: String,
        source: SessionOrigin,
        resolutionKind: ApprovalResolutionKind,
        createdAt: Date = .now,
        diagnosticMessage: String? = nil
    ) {
        self.requestID = requestID
        request = nil
        self.source = source
        self.resolutionKind = resolutionKind
        self.createdAt = createdAt
        self.diagnosticMessage = diagnosticMessage
    }
}
