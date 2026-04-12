//
//  ApprovalReducer.swift
//  HermitFlow
//
//  Phase 5 approval subsystem reducer.
//

import Foundation

struct ApprovalReducer {
    typealias State = ApprovalState

    mutating func apply(_ event: IslandEvent, state: inout State) {
        switch event {
        case let .approvalRequested(payload):
            setCurrentRequest(payload.request, state: &state)
        case let .approvalResolved(payload):
            markResolved(id: payload.requestID, state: &state)
        case let .diagnosticUpdated(diagnostics):
            state.diagnostic = diagnostics.approvalDiagnosticMessage.map {
                ApprovalDiagnostic(message: $0, severity: .info)
            }
        default:
            break
        }
    }

    mutating func setCurrentRequest(_ request: ApprovalRequest?, state: inout State) {
        guard let request else {
            return
        }

        guard !state.resolvedRequestIDs.contains(request.id) else {
            return
        }

        let previousRequestID = state.currentRequest?.id
        if let current = state.currentRequest {
            state.currentRequest = current.createdAt >= request.createdAt ? current : request
        } else {
            state.currentRequest = request
        }

        let currentRequestID = state.currentRequest?.id
        if currentRequestID != previousRequestID {
            if state.collapsedRequestID != currentRequestID {
                state.collapsedRequestID = nil
            }
            state.diagnostic = nil
            state.lastPresentedRequestID = currentRequestID
        }
    }

    mutating func markResolved(id: String, state: inout State) {
        state.resolvedRequestIDs.insert(id)

        if state.currentRequest?.id == id {
            state.currentRequest = nil
        }

        if state.previewRequest?.id == id {
            state.previewRequest = nil
        }

        if state.collapsedRequestID == id {
            state.collapsedRequestID = nil
        }

        state.diagnostic = nil
    }

    mutating func setCollapsedRequestID(_ id: String?, state: inout State) {
        state.collapsedRequestID = id
    }

    mutating func setPreviewRequest(_ request: ApprovalRequest?, state: inout State) {
        state.previewRequest = request
        if request != nil {
            state.diagnostic = nil
        }
    }

    mutating func setDiagnostic(_ diagnostic: ApprovalDiagnostic?, state: inout State) {
        state.diagnostic = diagnostic
    }

    mutating func clearStaleApproval(state: inout State) {
        state.currentRequest = nil
        state.previewRequest = nil
        state.collapsedRequestID = nil
        state.diagnostic = nil
    }

    mutating func syncCollapsedRequestID(_ requestID: String?, state: inout State) {
        state.collapsedRequestID = requestID
    }

    func resolvedApproval(
        state: State,
        previousApprovalRequest: ApprovalRequest?,
        incomingApprovalRequest: ApprovalRequest?
    ) -> ApprovalRequest? {
        if let previewRequest = state.previewRequest {
            return previewRequest
        }

        if let incomingApprovalRequest {
            return incomingApprovalRequest
        }

        guard
            let previousApprovalRequest,
            previousApprovalRequest.source == .codex,
            !state.resolvedRequestIDs.contains(previousApprovalRequest.id)
        else {
            return nil
        }

        return previousApprovalRequest
    }
}
