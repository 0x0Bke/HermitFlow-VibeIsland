import SwiftUI

struct DotMatrixWaveStatusGlyph: View {
    let isAnimating: Bool

    private let cycleDuration: Double = 0.92
    private let riseDuration: Double = 0.085
    private let fallDuration: Double = 0.22
    private let dotSize: CGFloat = 4.6
    private let dotSpacing: CGFloat = 0
    private let restingColor = Color(.sRGB, red: 29 / 255, green: 29 / 255, blue: 29 / 255, opacity: 0.6)
    private let secondaryColor = (red: 0.0, green: 184.0 / 255.0, blue: 212.0 / 255.0)
    private let activeColor = (red: 0.0, green: 229.0 / 255.0, blue: 1.0)
    private let peakPhases: [Double] = [
        0.00, 0.08, 0.23,
        0.08, 0.23, 0.38,
        0.23, 0.38, 0.53
    ]

    var body: some View {
        Group {
            if isAnimating {
                TimelineView(.animation(minimumInterval: 1.0 / 18.0, paused: false)) { timeline in
                    glyphBody(at: normalizedPhase(for: timeline.date))
                }
            } else {
                glyphBody(at: nil)
            }
        }
        .frame(width: 16.5, height: 16.5)
    }

    private func glyphBody(at phase: Double?) -> some View {
        VStack(spacing: dotSpacing) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: dotSpacing) {
                    ForEach(0..<3, id: \.self) { column in
                        let index = row * 3 + column
                        let intensity = dotIntensity(for: index, phase: phase)

                        RoundedRectangle(cornerRadius: 0.4, style: .continuous)
                            .fill(dotFill(intensity: intensity))
                            .frame(width: dotSize, height: dotSize)
                            .scaleEffect(1 + intensity * 0.09)
                    }
                }
            }
        }
    }

    private func normalizedPhase(for date: Date) -> Double {
        let elapsed = date.timeIntervalSinceReferenceDate
        return elapsed.truncatingRemainder(dividingBy: cycleDuration) / cycleDuration
    }

    private func dotIntensity(for index: Int, phase: Double?) -> Double {
        guard let phase else {
            return index == 0 ? 1 : 0
        }

        let peak = peakPhases[index]
        let riseStart = wrappedUnit(peak - riseDuration / cycleDuration)

        if phaseIsWithinInterval(phase, start: riseStart, end: peak) {
            let progress = intervalProgress(value: phase, start: riseStart, end: peak)
            return smoothStep(progress)
        }

        let fallEnd = wrappedUnit(peak + fallDuration / cycleDuration)
        if phaseIsWithinInterval(phase, start: peak, end: fallEnd) {
            let progress = intervalProgress(value: phase, start: peak, end: fallEnd)
            return 1 - smoothStep(progress)
        }

        return 0
    }

    private func dotFill(intensity: Double) -> some ShapeStyle {
        guard intensity > 0 else {
            return restingColor
        }

        let clamped = min(max(intensity, 0), 1)
        let red = secondaryColor.red + (activeColor.red - secondaryColor.red) * clamped
        let green = secondaryColor.green + (activeColor.green - secondaryColor.green) * clamped
        let blue = secondaryColor.blue + (activeColor.blue - secondaryColor.blue) * clamped

        return Color(.sRGB, red: red, green: green, blue: blue, opacity: 0.5 + clamped * 0.5)
    }

    private func wrappedUnit(_ value: Double) -> Double {
        let wrapped = value.truncatingRemainder(dividingBy: 1)
        return wrapped >= 0 ? wrapped : wrapped + 1
    }

    private func phaseIsWithinInterval(_ value: Double, start: Double, end: Double) -> Bool {
        if start <= end {
            return value >= start && value <= end
        }

        return value >= start || value <= end
    }

    private func intervalProgress(value: Double, start: Double, end: Double) -> Double {
        let adjustedEnd = end >= start ? end : end + 1
        let adjustedValue = value >= start ? value : value + 1
        let duration = max(adjustedEnd - start, .leastNonzeroMagnitude)
        return min(max((adjustedValue - start) / duration, 0), 1)
    }

    private func smoothStep(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return clamped * clamped * clamped * (clamped * (clamped * 6 - 15) + 10)
    }
}
