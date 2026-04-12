//
//  ApprovalInlineView.swift
//  HermitFlow
//
//  Phase 5 approval presentation wrapper.
//

import SwiftUI

struct ApprovalInlineView: View {
    @ObservedObject var store: ProgressStore
    let request: ApprovalRequest
    let header: AnyView
    let sessionTitle: String
    let primaryTitle: String
    let timestampText: String
    let diagnosticMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(red: 0.23, green: 0.51, blue: 0.95))

                    Text("Approval Needed")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)

                    Spacer(minLength: 8)

                    Button(action: store.collapseInlineApproval) {
                        Text("Hide")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.7))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 8)

                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 1)
                    .padding(.bottom, 12)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 8) {
                        Image(systemName: "terminal")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color(red: 0.63, green: 0.63, blue: 0.67))

                        Text("Session:")
                            .font(.system(size: 10, weight: .regular))
                            .foregroundStyle(Color(red: 0.44, green: 0.44, blue: 0.48))

                        Text(sessionTitle)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        Spacer(minLength: 8)

                        sourcePill
                    }

                    Text(primaryTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Command")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color(red: 0.44, green: 0.44, blue: 0.48))

                        Text(request.commandSummary.isEmpty ? "Waiting for command detail" : request.commandSummary)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.black.opacity(0.4))
                    )

                    Text(timestampText)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color(red: 0.44, green: 0.44, blue: 0.48))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.07), lineWidth: 1)
                )
                .padding(.bottom, 12)

                HStack(spacing: 8) {
                    decisionButton(
                        title: "Deny",
                        systemImage: "xmark",
                        titleColor: Color(red: 1.0, green: 0.42, blue: 0.42),
                        background: Color.white.opacity(0.08),
                        border: Color.white.opacity(0.08),
                        borderWidth: 1,
                        action: store.rejectApproval
                    )

                    decisionButton(
                        title: "Allow Once",
                        systemImage: "checkmark",
                        titleColor: .white,
                        background: Color(red: 0.13, green: 0.77, blue: 0.37),
                        action: store.acceptApproval
                    )

                    decisionButton(
                        title: "Always Allow",
                        systemImage: "checkmark.circle",
                        titleColor: Color(red: 0.63, green: 0.63, blue: 0.67),
                        iconColor: Color(red: 0.13, green: 0.77, blue: 0.37),
                        background: Color.white.opacity(0.06),
                        border: Color.white.opacity(0.09),
                        borderWidth: 1,
                        action: store.acceptAllApprovals
                    )
                }

                if let diagnosticMessage {
                    diagnosticCallout(diagnosticMessage)
                        .padding(.top, 10)
                }
            }
            .padding(.horizontal, 36)
            .padding(.top, 12)
        }
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var sourcePill: some View {
        Text(request.source.provider.displayName)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(request.source.provider.tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(request.source.provider.tint.opacity(0.14))
            )
    }

    private func decisionButton(
        title: String,
        systemImage: String,
        titleColor: Color,
        iconColor: Color? = nil,
        background: Color,
        border: Color = .clear,
        borderWidth: CGFloat = 0,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(iconColor ?? titleColor)

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(border, lineWidth: borderWidth)
            )
        }
        .buttonStyle(.plain)
    }

    private func diagnosticCallout(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(Color(red: 0.57, green: 0.83, blue: 1.0))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(red: 0.10, green: 0.20, blue: 0.33).opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(red: 0.57, green: 0.83, blue: 1.0).opacity(0.24), lineWidth: 1)
            )
    }
}
