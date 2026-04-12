//
//  ApprovalRequestMerger.swift
//  HermitFlow
//
//  Phase 4 shared source helpers.
//

import Foundation

enum ApprovalRequestMerger {
    static func merge(_ lhs: ApprovalRequest?, _ rhs: ApprovalRequest?) -> ApprovalRequest? {
        switch (lhs, rhs) {
        case let (left?, right?):
            return left.createdAt >= right.createdAt ? left : right
        case let (left?, nil):
            return left
        case let (nil, right?):
            return right
        case (nil, nil):
            return nil
        }
    }
}
