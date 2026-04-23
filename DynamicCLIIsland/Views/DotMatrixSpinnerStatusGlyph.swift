import AppKit
import SwiftUI

struct DotMatrixSpinnerStatusGlyph: View {
    let isAnimating: Bool

    private let cycleDuration: Double = 1.0
    private let riseDuration: Double = 0.12
    private let fallDuration: Double = 0.48
    private let dotSize: CGFloat = 4.6
    private let dotSpacing: CGFloat = 0
    private let restingColor = Color(.sRGB, red: 51 / 255, green: 51 / 255, blue: 51 / 255, opacity: 1)
    private let activeColor = Color(.sRGB, red: 1.0, green: 118 / 255, blue: 5 / 255, opacity: 1)

    private let orbitPhases: [Int: Double] = [
        1: 0.00,
        5: 0.12,
        7: 0.32,
        3: 0.52
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
                            .scaleEffect(1 + intensity * 0.1)
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
        if index == 4 {
            return 1
        }

        guard let phase, let peak = orbitPhases[index] else {
            return index == 1 ? 1 : 0
        }

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
        let baseColor = intensity > 0 ? activeColor : restingColor
        return baseColor.opacity(intensity > 0 ? 0.5 + intensity * 0.5 : 1)
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

struct LayerBackedDotMatrixSpinnerGlyph: NSViewRepresentable {
    let isAnimating: Bool

    func makeNSView(context: Context) -> DotMatrixSpinnerNSView {
        let view = DotMatrixSpinnerNSView()
        view.setAnimating(isAnimating)
        return view
    }

    func updateNSView(_ nsView: DotMatrixSpinnerNSView, context: Context) {
        nsView.setAnimating(isAnimating)
    }
}

final class DotMatrixSpinnerNSView: NSView {
    private let cycleDuration: CFTimeInterval = 1.0
    private let riseDuration: Double = 0.12
    private let fallDuration: Double = 0.48
    private let dotSize: CGFloat = 4.6
    private let dotSpacing: CGFloat = 0
    private let glyphSize: CGFloat = 16.5
    private let activeAnimationKey = "HermitFlow.spinner.activeOpacity"
    private let scaleAnimationKey = "HermitFlow.spinner.activeScale"

    private let baseColor = NSColor(
        calibratedRed: 51 / 255,
        green: 51 / 255,
        blue: 51 / 255,
        alpha: 1
    ).cgColor
    private let activeColor = NSColor(
        calibratedRed: 1.0,
        green: 118 / 255,
        blue: 5 / 255,
        alpha: 1
    ).cgColor

    private let orbitPhases: [Int: Double] = [
        1: 0.00,
        5: 0.12,
        7: 0.32,
        3: 0.52
    ]

    private var dotLayers: [CALayer] = []
    private var activeDotLayers: [CALayer] = []
    private var isCurrentlyAnimating = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupLayers()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupLayers()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: glyphSize, height: glyphSize)
    }

    override func layout() {
        super.layout()
        layoutDotLayers()
    }

    func setAnimating(_ isAnimating: Bool) {
        guard isAnimating != isCurrentlyAnimating else {
            return
        }

        isCurrentlyAnimating = isAnimating
        if isAnimating {
            startAnimations()
        } else {
            stopAnimations()
        }
    }

    private func setupLayers() {
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = false

        dotLayers = []
        activeDotLayers = []

        for index in 0..<9 {
            let baseLayer = makeDotLayer(color: baseColor)
            let activeLayer = makeDotLayer(color: activeColor)
            activeLayer.opacity = staticActiveOpacity(for: index)

            layer?.addSublayer(baseLayer)
            layer?.addSublayer(activeLayer)
            dotLayers.append(baseLayer)
            activeDotLayers.append(activeLayer)
        }

        layoutDotLayers()
    }

    private func makeDotLayer(color: CGColor) -> CALayer {
        let dotLayer = CALayer()
        dotLayer.backgroundColor = color
        dotLayer.cornerRadius = 0.4
        dotLayer.bounds = CGRect(x: 0, y: 0, width: dotSize, height: dotSize)
        dotLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        dotLayer.allowsEdgeAntialiasing = false
        dotLayer.actions = [
            "bounds": NSNull(),
            "position": NSNull(),
            "opacity": NSNull(),
            "transform": NSNull(),
            "backgroundColor": NSNull()
        ]
        return dotLayer
    }

    private func layoutDotLayers() {
        guard dotLayers.count == 9, activeDotLayers.count == 9 else {
            return
        }

        let gridWidth = dotSize * 3 + dotSpacing * 2
        let originX = (bounds.width - gridWidth) / 2
        let originY = (bounds.height - gridWidth) / 2

        for index in 0..<9 {
            let row = index / 3
            let column = index % 3
            let x = originX + CGFloat(column) * (dotSize + dotSpacing) + dotSize / 2
            let y = originY + CGFloat(2 - row) * (dotSize + dotSpacing) + dotSize / 2
            let position = CGPoint(x: x, y: y)

            dotLayers[index].position = position
            activeDotLayers[index].position = position
        }
    }

    private func startAnimations() {
        let currentTime = CACurrentMediaTime()

        for index in 0..<activeDotLayers.count {
            let activeLayer = activeDotLayers[index]
            activeLayer.removeAnimation(forKey: activeAnimationKey)
            activeLayer.removeAnimation(forKey: scaleAnimationKey)

            if index == 4 {
                activeLayer.opacity = 1
                activeLayer.transform = CATransform3DIdentity
                continue
            }

            guard let peak = orbitPhases[index] else {
                activeLayer.opacity = 0
                activeLayer.transform = CATransform3DIdentity
                continue
            }

            activeLayer.opacity = 0
            let opacityAnimation = keyframeAnimation(
                keyPath: "opacity",
                values: sampledValues(peak: peak) { intensity in
                    intensity > 0 ? Float(0.5 + intensity * 0.5) : 0
                }
            )
            opacityAnimation.beginTime = currentTime

            let scaleAnimation = keyframeAnimation(
                keyPath: "transform.scale",
                values: sampledValues(peak: peak) { intensity in
                    Float(1 + intensity * 0.1)
                }
            )
            scaleAnimation.beginTime = currentTime

            activeLayer.add(opacityAnimation, forKey: activeAnimationKey)
            activeLayer.add(scaleAnimation, forKey: scaleAnimationKey)
        }
    }

    private func stopAnimations() {
        for index in 0..<activeDotLayers.count {
            let activeLayer = activeDotLayers[index]
            activeLayer.removeAnimation(forKey: activeAnimationKey)
            activeLayer.removeAnimation(forKey: scaleAnimationKey)
            activeLayer.opacity = staticActiveOpacity(for: index)
            activeLayer.transform = CATransform3DIdentity
        }
    }

    private func keyframeAnimation(keyPath: String, values: [Float]) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = values.indices.map { index in
            NSNumber(value: Double(index) / Double(max(values.count - 1, 1)))
        }
        animation.duration = cycleDuration
        animation.repeatCount = .infinity
        animation.calculationMode = .linear
        animation.isRemovedOnCompletion = false
        return animation
    }

    private func sampledValues(
        peak: Double,
        transform: (Double) -> Float
    ) -> [Float] {
        let sampleCount = 48
        return (0...sampleCount).map { sample in
            let phase = Double(sample) / Double(sampleCount)
            return transform(dotIntensity(peak: peak, phase: phase))
        }
    }

    private func staticActiveOpacity(for index: Int) -> Float {
        index == 4 || index == 1 ? 1 : 0
    }

    private func dotIntensity(peak: Double, phase: Double) -> Double {
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
