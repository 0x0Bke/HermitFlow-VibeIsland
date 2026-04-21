//
//  ApprovalInlineView.swift
//  HermitFlow
//
//  Phase 5 approval presentation wrapper.
//

import AppKit
import SwiftUI

private enum ApprovalSelection: Int, CaseIterable {
    case deny
    case allowOnce
    case alwaysAllow

    func moveLeft() -> ApprovalSelection {
        ApprovalSelection(rawValue: max(rawValue - 1, 0)) ?? self
    }

    func moveRight() -> ApprovalSelection {
        ApprovalSelection(rawValue: min(rawValue + 1, Self.allCases.count - 1)) ?? self
    }
}

struct ApprovalInlineView: View {
    @ObservedObject var store: ProgressStore
    let request: ApprovalRequest
    let header: AnyView
    let sessionTitle: String
    let primaryTitle: String
    let timestampText: String
    let diagnosticMessage: String?
    let defaultFocus: ApprovalDefaultFocusOption

    @State private var selectedAction: ApprovalSelection = .allowOnce
    @State private var isCommandExpanded = false

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

                    if let supplementalRationaleText {
                        Text(supplementalRationaleText)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(Color.white.opacity(0.72))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text(timestampText)
                        .font(.system(size: 10, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color(red: 0.44, green: 0.44, blue: 0.48))

                    commandSection
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .layoutPriority(1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.08, green: 0.09, blue: 0.10).opacity(0.98),
                                    Color(red: 0.04, green: 0.05, blue: 0.06).opacity(0.96)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(red: 0.32, green: 0.96, blue: 0.38).opacity(0.20), lineWidth: 1)
                )
                .padding(.bottom, 12)
                .layoutPriority(1)

                HStack(spacing: 8) {
                    decisionButton(
                        selection: .deny,
                        title: "Deny",
                        systemImage: "xmark",
                        titleColor: Color(red: 1.0, green: 0.42, blue: 0.42),
                        background: Color.white.opacity(0.08),
                        border: Color.white.opacity(0.08),
                        borderWidth: 1,
                        action: store.rejectApproval
                    )

                    decisionButton(
                        selection: .allowOnce,
                        title: "Allow Once",
                        systemImage: "checkmark",
                        titleColor: .white,
                        background: Color(red: 0.13, green: 0.77, blue: 0.37),
                        action: store.acceptApproval
                    )

                    decisionButton(
                        selection: .alwaysAllow,
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            ApprovalInlineKeyboardBridge(
                requestID: request.id,
                onLeft: { selectedAction = selectedAction.moveLeft() },
                onRight: { selectedAction = selectedAction.moveRight() },
                onConfirm: performSelectedAction
            )
            .frame(width: 0, height: 0)
        )
        .onAppear(perform: resetSelection)
        .onChange(of: request.id) { _, _ in
            resetSelection()
        }
        .onChange(of: defaultFocus) { _, _ in
            resetSelection()
        }
        .onChange(of: store.inlineApprovalCommandExpanded) { _, newValue in
            isCommandExpanded = newValue
        }
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

    private var shouldShowCommandToggle: Bool {
        !commandText.isEmpty
    }

    private var commandText: String {
        request.commandText.isEmpty ? request.commandSummary : request.commandText
    }

    private var commandDisplayText: String {
        let command = commandText.isEmpty ? "Waiting for command detail" : commandText
        let breakableSeparators = ["/", "\\", " ", "-", "_", "=", ":", ","]
        return breakableSeparators.reduce(command) { partial, separator in
            partial.replacingOccurrences(of: separator, with: "\(separator)\u{200B}")
        }
    }

    private var supplementalRationaleText: String? {
        guard let rationale = request.displayRationale else {
            return nil
        }

        let normalizedPrimaryTitle = primaryTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rationale != normalizedPrimaryTitle else {
            return nil
        }

        return rationale
    }

    private var commandSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Text("Command")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color(red: 0.44, green: 0.44, blue: 0.48))

                Spacer(minLength: 8)

                if shouldShowCommandToggle {
                    Button(action: toggleCommandExpansion) {
                        Text(isCommandExpanded ? "Collapse" : "Expand")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.7))
                    }
                    .buttonStyle(.borderless)
                }
            }

            if isCommandExpanded {
                GeometryReader { geometry in
                    ScrollView(.vertical, showsIndicators: true) {
                        Text(commandDisplayText)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(commandForegroundColor)
                            .textSelection(.enabled)
                            .frame(width: max(geometry.size.width, 1), alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(minHeight: 170, maxHeight: .infinity, alignment: .topLeading)
                .id("command-expanded")
            } else {
                Text(commandDisplayText)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(commandForegroundColor)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .id("command-collapsed")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.4))
        )
    }

    private var commandAccentColor: Color {
        switch request.source.provider {
        case .claude:
            return Color(red: 1.00, green: 0.77, blue: 0.50)
        case .codex:
            return Color(red: 0.63, green: 0.88, blue: 1.00)
        case .openCode:
            return Color(red: 0.63, green: 0.93, blue: 0.68)
        case .generic:
            return Color(red: 0.74, green: 0.84, blue: 1.00)
        }
    }

    private var commandForegroundColor: Color {
        commandAccentColor.opacity(0.98)
    }

    private func decisionButton(
        selection: ApprovalSelection,
        title: String,
        systemImage: String,
        titleColor: Color,
        iconColor: Color? = nil,
        background: Color,
        border: Color = .clear,
        borderWidth: CGFloat = 0,
        action: @escaping () -> Void
    ) -> some View {
        let isSelected = selectedAction == selection

        return Button(action: {
            selectedAction = selection
            action()
        }) {
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
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(isSelected ? 0.10 : 0))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        isSelected ? Color.white.opacity(0.90) : border,
                        lineWidth: isSelected ? 1.5 : borderWidth
                    )
            )
            .shadow(
                color: isSelected ? Color.white.opacity(0.24) : .clear,
                radius: isSelected ? 8 : 0,
                y: isSelected ? 1 : 0
            )
            .scaleEffect(isSelected ? 1.01 : 1)
            .animation(.easeOut(duration: 0.12), value: isSelected)
        }
        .buttonStyle(.plain)
    }

    private func resetSelection() {
        selectedAction = switch defaultFocus {
        case .accept:
            .allowOnce
        case .acceptAll:
            .alwaysAllow
        }

        isCommandExpanded = false
        store.updateInlineApprovalCommandExpanded(false)
    }

    private func toggleCommandExpansion() {
        let nextValue = !isCommandExpanded
        isCommandExpanded = nextValue
        store.updateInlineApprovalCommandExpanded(nextValue)
    }

    private func performSelectedAction() {
        switch selectedAction {
        case .deny:
            store.rejectApproval()
        case .allowOnce:
            store.acceptApproval()
        case .alwaysAllow:
            store.acceptAllApprovals()
        }
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

private struct ApprovalInlineKeyboardBridge: NSViewRepresentable {
    let requestID: String
    let onLeft: () -> Void
    let onRight: () -> Void
    let onConfirm: () -> Void

    func makeNSView(context: Context) -> ApprovalInlineKeyboardView {
        let view = ApprovalInlineKeyboardView()
        view.onLeft = onLeft
        view.onRight = onRight
        view.onConfirm = onConfirm
        view.focusToken = requestID
        return view
    }

    func updateNSView(_ nsView: ApprovalInlineKeyboardView, context: Context) {
        nsView.onLeft = onLeft
        nsView.onRight = onRight
        nsView.onConfirm = onConfirm

        if nsView.focusToken != requestID {
            nsView.focusToken = requestID
            nsView.scheduleFocus()
        } else {
            nsView.scheduleFocusIfNeeded()
        }
    }
}

private final class ApprovalInlineKeyboardView: NSView {
    var onLeft: (() -> Void)?
    var onRight: (() -> Void)?
    var onConfirm: (() -> Void)?
    var focusToken: String?

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleFocus()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123:
            onLeft?()
        case 124:
            onRight?()
        case 36, 76:
            onConfirm?()
        default:
            super.keyDown(with: event)
        }
    }

    func scheduleFocus() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else {
                return
            }

            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(self)
        }
    }

    func scheduleFocusIfNeeded() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else {
                return
            }

            if window.isKeyWindow, window.firstResponder !== self {
                window.makeFirstResponder(self)
            }
        }
    }
}
