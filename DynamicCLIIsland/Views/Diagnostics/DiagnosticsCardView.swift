//
//  DiagnosticsCardView.swift
//  HermitFlow
//
//  Structured source diagnostics panel section.
//

import SwiftUI

struct DiagnosticsCardView: View {
    let reports: [SourceHealthReport]

    private var visibleReports: [SourceHealthReport] {
        reports.filter(\.hasIssues)
    }

    var body: some View {
        if !visibleReports.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 8) {
                    Text("Source Health")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)

                    Spacer(minLength: 8)
                }

                ForEach(visibleReports) { report in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(DiagnosticsFormatter.headline(for: report))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)

                        ForEach(report.issues) { issue in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(DiagnosticsFormatter.issueSummary(issue))
                                    .font(.system(size: 11, weight: .regular))
                                    .foregroundStyle(issueColor(issue.severity))
                                    .fixedSize(horizontal: false, vertical: true)

                                if issue.isRepairable {
                                    Text("Repair available locally.")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(Color.white.opacity(0.45))
                                }
                            }
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.05), lineWidth: 1)
            )
        }
    }

    private func issueColor(_ severity: DiagnosticIssue.Severity) -> Color {
        switch severity {
        case .info:
            return Color.white.opacity(0.72)
        case .warning:
            return Color(red: 1.0, green: 0.82, blue: 0.48)
        case .error:
            return Color(red: 1.0, green: 0.55, blue: 0.55)
        }
    }
}
