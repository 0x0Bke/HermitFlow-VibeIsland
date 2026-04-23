import SwiftUI

struct DotMatrixFailureStatusGlyph: View {
    let isAnimating: Bool

    private struct Pulse {
        let peak: Double
        let riseDuration: Double
        let fallDuration: Double
    }

    private let cycleDuration: Double = 0.96
    private let gridSize = 5
    private let dotSize: CGFloat = 3.05
    private let dotSpacing: CGFloat = 0.15
    private let restingColor = Color(.sRGB, red: 29 / 255, green: 29 / 255, blue: 29 / 255, opacity: 0.72)
    private let secondaryColor = (red: 210.0 / 255.0, green: 56.0 / 255.0, blue: 72.0 / 255.0)
    private let activeColor = (red: 1.0, green: 92.0 / 255.0, blue: 110.0 / 255.0)
    private let crossPathIndices: [Int] = [0, 6, 12, 8, 4, 16, 20, 18, 24]

    private let pulsesByDot: [[Pulse]] = [
        [Pulse(peak: 0.00, riseDuration: 0.08, fallDuration: 0.42)],
        [], [], [], [Pulse(peak: 0.24, riseDuration: 0.08, fallDuration: 0.42)],
        [], [Pulse(peak: 0.08, riseDuration: 0.08, fallDuration: 0.48)], [], [Pulse(peak: 0.16, riseDuration: 0.08, fallDuration: 0.48)], [],
        [], [], [Pulse(peak: 0.32, riseDuration: 0.08, fallDuration: 0.54)], [], [],
        [], [Pulse(peak: 0.40, riseDuration: 0.08, fallDuration: 0.46)], [], [Pulse(peak: 0.48, riseDuration: 0.08, fallDuration: 0.46)], [],
        [Pulse(peak: 0.56, riseDuration: 0.08, fallDuration: 0.40)], [], [], [], [Pulse(peak: 0.64, riseDuration: 0.08, fallDuration: 0.40)]
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
            ForEach(0..<gridSize, id: \.self) { row in
                HStack(spacing: dotSpacing) {
                    ForEach(0..<gridSize, id: \.self) { column in
                        let index = row * gridSize + column
                        let intensity = dotIntensity(for: index, phase: phase)

                        RoundedRectangle(cornerRadius: 0.35, style: .continuous)
                            .fill(dotFill(intensity: intensity))
                            .frame(width: dotSize, height: dotSize)
                            .scaleEffect(1 + intensity * 0.08)
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
            return crossPathIndices.contains(index) ? 1 : 0
        }

        let sweepIntensity = pulsesByDot[index].reduce(0) { current, pulse in
            max(current, pulseIntensity(for: pulse, phase: phase))
        }

        guard crossPathIndices.contains(index) else {
            return sweepIntensity
        }

        return max(sweepIntensity, lockGlowIntensity(for: phase))
    }

    private func pulseIntensity(for pulse: Pulse, phase: Double) -> Double {
        let riseStart = wrappedUnit(pulse.peak - pulse.riseDuration / cycleDuration)
        if phaseIsWithinInterval(phase, start: riseStart, end: pulse.peak) {
            let progress = intervalProgress(value: phase, start: riseStart, end: pulse.peak)
            return smoothStep(progress)
        }

        let fallEnd = wrappedUnit(pulse.peak + pulse.fallDuration / cycleDuration)
        if phaseIsWithinInterval(phase, start: pulse.peak, end: fallEnd) {
            let progress = intervalProgress(value: phase, start: pulse.peak, end: fallEnd)
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

        return Color(.sRGB, red: red, green: green, blue: blue, opacity: 0.56 + clamped * 0.44)
    }

    private func lockGlowIntensity(for phase: Double) -> Double {
        let lockPeak = 0.72
        let lockRiseDuration = 0.04
        let lockFallDuration = 0.12
        let pulse = Pulse(peak: lockPeak, riseDuration: lockRiseDuration, fallDuration: lockFallDuration)
        return pulseIntensity(for: pulse, phase: phase) * 0.18
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
