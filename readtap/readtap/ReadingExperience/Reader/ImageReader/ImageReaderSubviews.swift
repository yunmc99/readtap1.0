import SwiftUI

struct OCRWordOverlay: View {
  let words: [OCRWord]
  let imageSize: CGSize
  let fitRect: CGRect
  let containerSize: CGSize
  let longPressEnabled: Bool
  let onPressingChanged: (Bool) -> Void
  let onSelect: (MappedWord) -> Void
  let onLongPressFallback: (CGPoint) -> Void
  private let longPressDuration: Double = 0.28

  var body: some View {
    let mapped = words.map { word in
      MappedWord(
        id: word.id,
        text: word.text,
        rect: mapNormalizedRectToViewRect(word.boundingBox, imageSize: imageSize, fitRect: fitRect),
        normalizedRect: word.boundingBox
      )
    }

    let base = ZStack {}
      .frame(width: containerSize.width, height: containerSize.height)
      .contentShape(Rectangle())

    if longPressEnabled {
      base
        .allowsHitTesting(true)
        .simultaneousGesture(longPressGesture(mapped))
    } else {
      base.allowsHitTesting(false)
    }
  }

  private func longPressGesture(_ mapped: [MappedWord]) -> some Gesture {
    let longPress = LongPressGesture(minimumDuration: longPressDuration)
      .onChanged { _ in
        onPressingChanged(true)
      }
      .onEnded { _ in
        onPressingChanged(false)
      }

    return
      longPress
      .sequenced(
        before: DragGesture(minimumDistance: 0, coordinateSpace: .named("ImageReaderSpace"))
      )
      .onEnded { value in
        onPressingChanged(false)
        guard case .second(true, let drag?) = value else { return }
        let location = drag.location
        if let hit = nearestWord(to: location, in: mapped) {
          onSelect(hit)
        } else {
          onLongPressFallback(location)
        }
      }
  }

  private func nearestWord(to point: CGPoint, in mapped: [MappedWord]) -> MappedWord? {
    let items = mapped.map { WordSnap.Item(value: $0, rect: $0.rect) }
    let accept: (CGFloat, CGRect) -> Bool = { distance, rect in
      let minSide = min(rect.width, rect.height)
      let maxDistance = max(36, minSide * 1.5)
      return distance <= maxDistance
    }
    return WordSnap.pickLineFirst(point: point, items: items, accept: accept)?.value
  }
}

struct ImageReaderLoadingPulseView: View {
  let tick: Int
  @EnvironmentObject private var appSettings: AppSettings
  private var theme: LibraryTheme { appSettings.theme }

  var body: some View {
    HStack(spacing: 10) {
      ForEach(0..<3, id: \.self) { index in
        Circle()
          .fill(theme.cardStroke.opacity(index == tick ? 0.9 : 0.2))
          .frame(width: 9, height: 9)
          .scaleEffect(index == tick ? 1.25 : 0.95)
          .animation(.easeInOut(duration: 0.5), value: tick)
      }
    }
    .padding(.bottom, 2)
  }
}
