//
//  ApprovalSource.swift
//  HermitFlow
//
//  Phase 1 scaffold for the ongoing runtime refactor.
//

import Foundation

/// Shared minimal read interface for future approval providers.
///
/// Some legacy sources currently expose richer APIs; this protocol reserves the
/// future lowest-common-denominator read surface.
protocol ApprovalSource {
    func fetchApprovalRequest() -> ApprovalRequest?
}
