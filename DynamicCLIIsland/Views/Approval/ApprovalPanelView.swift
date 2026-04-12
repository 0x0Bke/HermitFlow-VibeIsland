//
//  ApprovalPanelView.swift
//  HermitFlow
//
//  Phase 5 approval presentation wrapper.
//

import SwiftUI

struct ApprovalPanelView: View {
    @ObservedObject var store: ProgressStore
    let request: ApprovalRequest
    let sessionTitle: String
    let primaryTitle: String
    let timestampText: String
    let diagnosticMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "bolt.badge.clock")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(red: 0.48, green: 0.84, blue: 0.99))

                        Text("Approval Request")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)

                        pendingBadge
                    }

                    HStack(alignment: .center, spacing: 8) {
                        sourcePill

                        Text(sessionTitle)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.68))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                Text(timestampText)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.48))
            }

            VStack(alignment: .leading, spacing: 10) {
                Text(primaryTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)

                sectionBlock(title: "Command", systemImage: "terminal", tint: Color(red: 0.48, green: 0.84, blue: 0.99), background: Color.black.opacity(0.5)) {
                    Text(request.commandSummary.isEmpty ? "Waiting for command detail" : request.commandSummary)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let rationale = request.rationale, !rationale.isEmpty {
                    sectionBlock(title: "Reason", systemImage: "text.alignleft", tint: Color(red: 0.99, green: 0.80, blue: 0.46), background: Color.white.opacity(0.05)) {
                        Text(rationale)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(Color.white.opacity(0.76))
                            .lineLimit(4)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let diagnosticMessage {
                diagnosticCallout(diagnosticMessage)
            }

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
                    titleColor: Color.white.opacity(0.74),
                    iconColor: Color(red: 0.13, green: 0.77, blue: 0.37),
                    background: Color.white.opacity(0.06),
                    border: Color.white.opacity(0.09),
                    borderWidth: 1,
                    action: store.acceptAllApprovals
                )
            }

            if let focusTarget = request.focusTarget {
                HStack(alignment: .center, spacing: 10) {
                    metaChip(systemImage: "macwindow", text: "Target: \(focusTarget.displayName)")

                    Spacer(minLength: 8)

                    Button(action: { store.bringForward(focusTarget) }) {
                        Text("Bring Forward")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.82))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.white.opacity(0.08))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("Awaiting action in the active CLI session. Return to Claude Code or Codex to allow, deny, or allow all.")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.54))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.14, green: 0.18, blue: 0.26).opacity(0.98),
                            Color(red: 0.09, green: 0.12, blue: 0.18).opacity(0.96)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color(red: 0.33, green: 0.78, blue: 0.95).opacity(0.26), lineWidth: 1)
        )
    }

    private var pendingBadge: some View {
        Text("Pending")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color(red: 0.33, green: 0.78, blue: 0.95))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(Color(red: 0.33, green: 0.78, blue: 0.95).opacity(0.14))
            )
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

    private func sectionBlock<Content: View>(
        title: String,
        systemImage: String,
        tint: Color,
        background: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)

                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.56))
            }

            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(background)
        )
    }

    private func metaChip(systemImage: String, text: String) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.52))

            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.64))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.06))
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
                    .minimumScaleFactor(0.9)
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
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color(red: 0.57, green: 0.83, blue: 1.0))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(red: 0.10, green: 0.20, blue: 0.33).opacity(0.92))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color(red: 0.57, green: 0.83, blue: 1.0).opacity(0.24), lineWidth: 1)
            )
    }
}
