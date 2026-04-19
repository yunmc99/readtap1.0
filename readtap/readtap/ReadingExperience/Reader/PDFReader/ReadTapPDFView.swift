//
//  ReadTapPDFView.swift
//  readtap
//
//  Created by 윤민채 on 2/6/26.
//

import Foundation
@preconcurrency import PDFKit
import PencilKit
import UIKit

@MainActor

final class ReadTapPDFView: PDFView, PKCanvasViewDelegate {
  enum DrawingInkKind {
    case pen
    case highlighter
  }

  enum DrawingWidthPreset {
    case thin
    case medium
    case bold
  }

  enum DrawingEraserKind {
    case stroke
    case partial
  }

  private static let lookupHighlightTag: Int = 927_102
  private var lookupHighlightView: UIView?
  private var lookupHighlightRectOnPage: CGRect?
  private var lookupHighlightPage: PDFPage?
  private var scaleObserver: NSObjectProtocol?
  private var landscapeSwipePan: UIPanGestureRecognizer?
  private var landscapeSwipeLastTurnAt: Date = .distantPast
  private let landscapeSwipeMinDistance: CGFloat = 42
  private let landscapeSwipeMaxVerticalRatio: CGFloat = 0.55
  private let landscapeSwipeMinVelocity: CGFloat = 280
  private let landscapeSwipeCooldown: TimeInterval = 0.28
  private let drawingOverlayProvider = PDFDrawingOverlayProvider()
  private let drawingCanvas = PKCanvasView(frame: .zero)
  private var isDrawingCanvasInstalled = false
  private var isDrawingEnabled = false
  private var drawingBookId: String?
  private var drawingCurrentPageIndex: Int?
  private var drawingCurrentTool: PKTool = PKInkingTool(.pen, color: .systemBlue, width: 3.4)
  private var drawingSaveWorkItem: DispatchWorkItem?
  private var drawingRefreshWorkItem: DispatchWorkItem?
  private var isApplyingLoadedDrawing = false
  private var didRegisterDrawingObservers = false
  private var isDrawingLayerVisible = true
  private var isLookupSelectionEnabled = true
  override var canBecomeFirstResponder: Bool { true }

  private var zoomedPageSwipe: UIPanGestureRecognizer?

  deinit {
    drawingRefreshWorkItem?.cancel()
    if didRegisterDrawingObservers {
      NotificationCenter.default.removeObserver(
        self, name: Notification.Name.PDFViewPageChanged, object: self)
      NotificationCenter.default.removeObserver(
        self, name: Notification.Name.PDFViewScaleChanged, object: self)
    }
  }

  func configureDrawingPersistence(bookId: String) {
    guard drawingBookId != bookId else { return }
    drawingBookId = bookId
    ensureDrawingOverlayProviderAttached()
    drawingOverlayProvider.setBookId(bookId)
    drawingOverlayProvider.setVisible(isDrawingLayerVisible)
    drawingOverlayProvider.setEnabled(isDrawingEnabled && isDrawingLayerVisible)
  }

  func prepareDrawingOverlayIfNeeded() {
    registerDrawingObserversIfNeeded()
    ensureDrawingOverlayProviderAttached()
    if let drawingBookId {
      drawingOverlayProvider.setBookId(drawingBookId)
    }
    drawingOverlayProvider.setVisible(isDrawingLayerVisible)
    drawingOverlayProvider.setEnabled(false)
    isDrawingEnabled = false
  }

  func setNavigationEnabled(_ enabled: Bool) {
    zoomedPageSwipe?.isEnabled = enabled
    landscapeSwipePan?.isEnabled = enabled
  }

  func setLookupSelectionEnabled(_ enabled: Bool) {
    isLookupSelectionEnabled = enabled
    if !enabled {
      clearSelection()
      forceClearSelection()
    }
  }

  func isLookupSelectionActive() -> Bool {
    return isLookupSelectionEnabled
  }

  func setDrawingEnabled(_ enabled: Bool) {
    registerDrawingObserversIfNeeded()
    ensureDrawingOverlayProviderAttached()
    guard isDrawingEnabled != enabled else { return }
    isDrawingEnabled = enabled
    setNavigationEnabled(!enabled)
    drawingOverlayProvider.setVisible(isDrawingLayerVisible)
    drawingOverlayProvider.setEnabled(enabled && isDrawingLayerVisible)
    if enabled {
      if let page = currentPage {
        go(to: page)
      }
      refreshDrawingOverlayNow(maxRetries: 4)
      DispatchQueue.main.async { [weak self] in
        self?.refreshDrawingOverlayNow(maxRetries: 6)
      }
      forceClearSelection()
      clearLookupHighlight(immediate: true)
    } else {
      drawingOverlayProvider.flushPendingPersistNow()
    }
  }

  func setDrawingLayerVisible(_ visible: Bool) {
    guard isDrawingLayerVisible != visible else { return }
    isDrawingLayerVisible = visible
    ensureDrawingOverlayProviderAttached()
    drawingOverlayProvider.setVisible(visible)
    drawingOverlayProvider.setEnabled(isDrawingEnabled && visible)
  }

  func refreshDrawingOverlayNow(maxRetries: Int = 8) {
    drawingRefreshWorkItem?.cancel()
    registerDrawingObserversIfNeeded()
    ensureDrawingOverlayProviderAttached()
    if let drawingBookId {
      drawingOverlayProvider.setBookId(drawingBookId)
    }
    drawingOverlayProvider.setVisible(isDrawingLayerVisible)
    drawingOverlayProvider.setEnabled(isDrawingEnabled && isDrawingLayerVisible)
    drawingOverlayProvider.refreshVisibleCanvases()
    let hasCanvas = drawingOverlayProvider.hasCanvasForCurrentPage()
    guard hasCanvas == false, maxRetries > 0 else { return }
    let shouldForceRebind = (maxRetries == 6 || maxRetries == 3)
    let work = DispatchWorkItem { [weak self] in
      guard let self else { return }
      if shouldForceRebind {
        self.ensureDrawingOverlayProviderAttached(forceRebind: true)
      }
      self.refreshDrawingOverlayNow(maxRetries: maxRetries - 1)
    }
    drawingRefreshWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: work)
  }

  func setDrawingInkTool(
    _ kind: DrawingInkKind,
    color: UIColor,
    widthPreset: DrawingWidthPreset = .medium
  ) {
    let tool: PKInkingTool
    switch kind {
    case .pen:
      tool = PKInkingTool(.pen, color: color, width: inkWidth(for: kind, preset: widthPreset))
    case .highlighter:
      tool = PKInkingTool(
        .marker,
        color: color.withAlphaComponent(0.9),
        width: inkWidth(for: kind, preset: widthPreset)
      )
    }
    drawingCurrentTool = tool
    ensureDrawingOverlayProviderAttached()
    drawingOverlayProvider.setInkTool(kind, color: color, widthPreset: widthPreset)
  }

  func setDrawingEraserTool(_ kind: DrawingEraserKind) {
    let eraserType: PKEraserTool.EraserType = (kind == .partial) ? .bitmap : .vector
    let tool = PKEraserTool(eraserType)
    drawingCurrentTool = tool
    ensureDrawingOverlayProviderAttached()
    drawingOverlayProvider.setEraser(kind)
  }

  func drawingUndo() {
    ensureDrawingOverlayProviderAttached()
    drawingOverlayProvider.undo()
  }

  func drawingRedo() {
    ensureDrawingOverlayProviderAttached()
    drawingOverlayProvider.redo()
  }

  private func inkWidth(for kind: DrawingInkKind, preset: DrawingWidthPreset) -> CGFloat {
    switch (kind, preset) {
    case (.pen, .thin):
      return 2.2
    case (.pen, .medium):
      return 3.4
    case (.pen, .bold):
      return 4.8
    case (.highlighter, .thin):
      return 10.0
    case (.highlighter, .medium):
      return 14.0
    case (.highlighter, .bold):
      return 18.0
    }
  }

  override func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
  ) -> Bool {
    if gestureRecognizer == zoomedPageSwipe || gestureRecognizer == landscapeSwipePan {
      // Allow simultaneous recognition with internal scroll view pan,
      // but not between our own page gestures.
      if other == zoomedPageSwipe || other == landscapeSwipePan {
        return false
      }
      return true
    }
    return false
  }

  override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    return super.gestureRecognizerShouldBegin(gestureRecognizer)
  }

  private func refreshDrawingOverlayForCurrentPage() {
    refreshDrawingOverlayNow(maxRetries: 2)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    applyCanvasAppearance()
    drawingOverlayProvider.refreshVisibleCanvases()
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    guard window != nil else { return }
    applyCanvasAppearance()
    if let scrollView = findInternalScrollView() {
      scrollView.contentInsetAdjustmentBehavior = .never
    }
    refreshDrawingOverlayNow()
    DispatchQueue.main.async { [weak self] in
      self?.refreshDrawingOverlayNow()
    }
  }

  @objc private func handleDrawingPageChanged() {
    refreshDrawingOverlayNow(maxRetries: 3)
  }

  @objc private func handleDrawingScaleChanged() {
    drawingOverlayProvider.refreshVisibleCanvases()
  }

  private func registerDrawingObserversIfNeeded() {
    guard !didRegisterDrawingObservers else { return }
    didRegisterDrawingObservers = true
    NotificationCenter.default.addObserver(
      self, selector: #selector(handleDrawingPageChanged),
      name: Notification.Name.PDFViewPageChanged, object: self)
    NotificationCenter.default.addObserver(
      self, selector: #selector(handleDrawingScaleChanged),
      name: Notification.Name.PDFViewScaleChanged, object: self)
  }

  private func ensureDrawingOverlayProviderAttached(forceRebind: Bool = false) {
    drawingOverlayProvider.attach(to: self)
    let currentProvider = pageOverlayViewProvider as AnyObject?
    if forceRebind || currentProvider !== drawingOverlayProvider {
      if forceRebind {
        pageOverlayViewProvider = nil
      }
      pageOverlayViewProvider = drawingOverlayProvider
    }
  }

  private func ensureDrawingCanvasInstalled() {
    let hostView = drawingHostView()
    if drawingCanvas.superview !== hostView {
      drawingCanvas.removeFromSuperview()
      hostView.addSubview(drawingCanvas)
    }
    guard !isDrawingCanvasInstalled else { return }
    isDrawingCanvasInstalled = true
    drawingCanvas.backgroundColor = .clear
    drawingCanvas.isOpaque = false
    drawingCanvas.delegate = self
    drawingCanvas.drawingPolicy = .anyInput
    drawingCanvas.tool = drawingCurrentTool
    drawingCanvas.isUserInteractionEnabled = false
    drawingCanvas.isHidden = true
  }

  @discardableResult
  private func updateDrawingCanvasLayout(syncPage: Bool) -> Bool {
    guard let page = currentPage, let document = document else {
      drawingCanvas.isHidden = !isDrawingLayerVisible
      drawingCanvas.isUserInteractionEnabled = isDrawingEnabled && isDrawingLayerVisible
      return false
    }
    ensureDrawingCanvasInstalled()
    let hostView = drawingHostView()

    let pageBounds = page.bounds(for: displayBox)
    let rectInSelf = convert(pageBounds, from: page)
    let rectInHostView: CGRect
    if hostView === self {
      rectInHostView = rectInSelf.integral
    } else {
      rectInHostView = hostView.convert(rectInSelf, from: self).integral
    }

    if rectInHostView.isNull == false, rectInHostView.isEmpty == false {
      drawingCanvas.frame = rectInHostView
    }

    let pageIndex = document.index(for: page)
    if syncPage || drawingCurrentPageIndex != pageIndex {
      persistCurrentPageDrawing(immediate: true)
      drawingCurrentPageIndex = pageIndex
      loadDrawingForCurrentPage()
    }

    drawingCanvas.isHidden = !isDrawingLayerVisible
    drawingCanvas.isUserInteractionEnabled = isDrawingEnabled && isDrawingLayerVisible
    drawingCanvas.tool = drawingCurrentTool
    if isDrawingLayerVisible {
      hostView.bringSubviewToFront(drawingCanvas)
    }
    return true
  }

  private func drawingHostView() -> UIView {
    if let documentView {
      return documentView
    }
    if let scrollView = findInternalScrollView() {
      return scrollView
    }
    return self
  }

  private func loadDrawingForCurrentPage() {
    guard let bookId = drawingBookId, let pageIndex = drawingCurrentPageIndex else { return }
    let data = BookDrawingStore.shared.load(bookId: bookId)[pageIndex]
    let drawing = data.flatMap { try? PKDrawing(data: $0) } ?? PKDrawing()
    isApplyingLoadedDrawing = true
    drawingCanvas.drawing = drawing
    isApplyingLoadedDrawing = false
  }

  private func persistCurrentPageDrawing(immediate: Bool) {
    guard isApplyingLoadedDrawing == false else { return }
    guard let bookId = drawingBookId, let pageIndex = drawingCurrentPageIndex else { return }
    let data =
      drawingCanvas.drawing.strokes.isEmpty ? nil : drawingCanvas.drawing.dataRepresentation()
    drawingSaveWorkItem?.cancel()
    drawingSaveWorkItem = nil

    if immediate {
      BookDrawingStore.shared.save(bookId: bookId, pageIndex: pageIndex, drawingData: data)
      return
    }

    let work = DispatchWorkItem {
      BookDrawingStore.shared.save(bookId: bookId, pageIndex: pageIndex, drawingData: data)
    }
    drawingSaveWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
  }

  func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
    persistCurrentPageDrawing(immediate: false)
  }

  /// Install a reliable horizontal pan for page turns in landscape twoUp mode.
  /// (usePageViewController is disabled in twoUp, so we handle page turns ourselves).
  func installLandscapeSwipeGestures() {
    guard landscapeSwipePan == nil else { return }
    let pan = UIPanGestureRecognizer(target: self, action: #selector(handleLandscapeSwipe(_:)))
    pan.minimumNumberOfTouches = 1
    pan.maximumNumberOfTouches = 1
    pan.delegate = self
    pan.cancelsTouchesInView = false
    addGestureRecognizer(pan)
    landscapeSwipePan = pan
  }

  func removeLandscapeSwipeGestures() {
    if let g = landscapeSwipePan {
      removeGestureRecognizer(g)
      landscapeSwipePan = nil
    }
  }

  /// Configure scroll view for portrait mode page turns.
  func configureScrollViewForPortrait() {
    guard let scrollView = findInternalScrollView() else { return }
    scrollView.isDirectionalLockEnabled = true
  }

  func restoreScrollViewDefaults() {
    guard let scrollView = findInternalScrollView() else { return }
    scrollView.isDirectionalLockEnabled = false
  }

  /// Install a pan gesture that turns pages when zoomed in and content is scrolled to the edge.
  func installZoomedPageSwipe() {
    guard zoomedPageSwipe == nil else { return }
    let pan = UIPanGestureRecognizer(target: self, action: #selector(handleZoomedPageSwipe(_:)))
    pan.delegate = self
    pan.minimumNumberOfTouches = 1
    pan.maximumNumberOfTouches = 1
    addGestureRecognizer(pan)
    zoomedPageSwipe = pan
  }

  @objc private func handleZoomedPageSwipe(_ gesture: UIPanGestureRecognizer) {
    let fit = scaleFactorForSizeToFit
    guard fit > 0 else { return }
    // In landscape twoUp, landscapeSwipePan handles page turns instead.
    // In portrait singlePage, usePageViewController handles page turns natively.
    if displayMode == .twoUp {
      return
    }
    let isPortraitSinglePage = displayMode == .singlePage && bounds.width <= bounds.height
    if isPortraitSinglePage {
      return
    }

    switch gesture.state {
    case .began:
      break
    case .ended:
      let velocity = gesture.velocity(in: self).x
      let translation = gesture.translation(in: self).x
      let translationY = gesture.translation(in: self).y
      let isSwipeLeft = velocity < 0 || (velocity == 0 && translation < 0)
      let absX = abs(translation)
      let absY = abs(translationY)

      // Direction filter: must be primarily horizontal
      guard absX > landscapeSwipeMinDistance else { return }
      guard absY < absX * landscapeSwipeMaxVerticalRatio else { return }
      guard abs(velocity) > landscapeSwipeMinVelocity else { return }

      // When zoomed beyond fit-to-page, require scroll edge before turning
      let isZoomed = scaleFactor > fit * 1.03
      if isZoomed {
        let atEdge: Bool
        if let scrollView = findInternalScrollView() {
          let offset = scrollView.contentOffset.x
          let maxOffset = scrollView.contentSize.width - scrollView.bounds.width
          atEdge = isSwipeLeft ? (offset >= maxOffset - 2) : (offset <= 2)
        } else {
          atEdge = true
        }
        guard atEdge else { return }
      }

      guard canStartPageTurn(at: Date()) else { return }
      animatePageTurn(forward: isSwipeLeft)
    default:
      break
    }
  }

  @objc private func handleLandscapeSwipe(_ gesture: UIPanGestureRecognizer) {
    switch gesture.state {
    case .began:
      break
    case .ended:
      let velocity = gesture.velocity(in: self).x
      let translation = gesture.translation(in: self).x
      let translationY = gesture.translation(in: self).y
      let isSwipeLeft = velocity < 0 || (velocity == 0 && translation < 0)
      let absX = abs(translation)
      let absY = abs(translationY)
      guard absX > landscapeSwipeMinDistance else { return }
      guard absY < absX * landscapeSwipeMaxVerticalRatio else { return }
      let velocityOk = abs(velocity) > landscapeSwipeMinVelocity
      let distanceOk = absX > landscapeSwipeMinDistance * 1.8
      guard velocityOk || distanceOk else { return }

      guard isInLandscapeScrollEdge(forward: isSwipeLeft) else { return }
      guard canStartPageTurn(at: Date()) else { return }
      animatePageTurn(forward: isSwipeLeft)
    default:
      break
    }
  }

  private func canStartPageTurn(at now: Date) -> Bool {
    let elapsed = now.timeIntervalSince(landscapeSwipeLastTurnAt)
    guard elapsed > landscapeSwipeCooldown else { return false }
    landscapeSwipeLastTurnAt = now
    return true
  }

  private func isInLandscapeScrollEdge(forward: Bool) -> Bool {
    guard displayMode == .twoUp else { return true }
    guard let scrollView = findInternalScrollView() else { return true }
    let maxOffset = max(0, scrollView.contentSize.width - scrollView.bounds.width)
    let offset = scrollView.contentOffset.x
    if forward {
      return offset >= maxOffset - 2
    }
    return offset <= 2
  }

  private func animatePageTurn(forward: Bool) {
    let transition = CATransition()
    transition.type = .push
    transition.subtype = forward ? .fromRight : .fromLeft
    transition.duration = 0.3
    transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
    layer.add(transition, forKey: "pageSwipe")

    if forward {
      goToNextPage(nil)
    } else {
      goToPreviousPage(nil)
    }
  }

  private func findInternalScrollView() -> UIScrollView? {
    for sub in subviews {
      if let sv = sub as? UIScrollView { return sv }
      for sub2 in sub.subviews {
        if let sv = sub2 as? UIScrollView { return sv }
      }
    }
    return nil
  }

  func applyCanvasAppearance() {
    let isRefined = ReaderVisualStyleMode.current.isRefined
    let canvasColor = isRefined ? ReaderRefinedPalette.canvasUIColor : UIColor.clear
    let pageCanvasColor = isRefined ? ReaderRefinedPalette.pageCanvasUIColor : UIColor.clear

    backgroundColor = canvasColor
    isOpaque = !isRefined

    if let scrollView = findInternalScrollView() {
      scrollView.backgroundColor = canvasColor
      scrollView.isOpaque = !isRefined
    }

    if let documentView {
      documentView.backgroundColor = pageCanvasColor
      documentView.isOpaque = !isRefined
    }
  }

  override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
    let autoSaveEnabled = UserDefaults.standard.object(forKey: "autoSaveEnabled") as? Bool ?? true
    if !isLookupSelectionEnabled {
      return false
    }

    if !autoSaveEnabled {
      switch action {
      case #selector(highlightSelection(_:)),
        #selector(underlineSelection(_:)):
        return currentSelection != nil
      default:
        break
      }
      return super.canPerformAction(action, withSender: sender)
    }

    // When auto-save is ON, keep long-press focused on lookup + saving, not the system edit menu.
    switch action {
    case #selector(copy(_:)),
      #selector(paste(_:)),
      #selector(cut(_:)),
      #selector(select(_:)),
      #selector(selectAll(_:)),
      #selector(delete(_:)):
      return false
    default:
      return super.canPerformAction(action, withSender: sender)
    }
  }

  @objc func highlightSelection(_ sender: Any?) {
    addMarkup(
      type: .highlight,
      color: ReaderVisualStyleMode.current.isRefined
        ? ReaderRefinedPalette.markupHighlight
        : UIColor.systemYellow.withAlphaComponent(0.55)
    )
  }

  @objc func underlineSelection(_ sender: Any?) {
    addMarkup(type: .underline, color: UIColor.systemOrange.withAlphaComponent(0.85))
  }

  private func addMarkup(type: PDFAnnotationSubtype, color: UIColor) {
    guard let selection = currentSelection else { return }
    guard let doc = document else { return }

    let typeString = annotationTypeString(for: type)
    let lineSelections = selection.selectionsByLine()
    for line in lineSelections {
      for page in line.pages {
        let bounds = line.bounds(for: page)
        if bounds.isEmpty { continue }
        // Toggle behavior: if an existing markup of the same subtype overlaps this line,
        // remove it; otherwise add it.
        let existing = page.annotations.filter { ($0.type ?? "") == typeString }
        let matches = existing.filter { isSameMarkup($0.bounds, bounds) }
        if !matches.isEmpty {
          for ann in matches {
            page.removeAnnotation(ann)
          }
        } else {
          let annotation = PDFAnnotation(bounds: bounds, forType: type, withProperties: nil)
          annotation.color = color
          page.addAnnotation(annotation)
        }
      }
    }

    clearSelection()

    if let url = doc.documentURL {
      _ = doc.write(to: url)
    }
  }

  private func isSameMarkup(_ existing: CGRect, _ target: CGRect) -> Bool {
    guard existing.intersects(target) else { return false }
    let intersection = existing.intersection(target)
    if intersection.isNull || intersection.isEmpty { return false }

    let a1 = max(1, existing.width * existing.height)
    let a2 = max(1, target.width * target.height)
    let ai = intersection.width * intersection.height
    let ratio = ai / min(a1, a2)
    return ratio >= 0.7
  }

  private func annotationTypeString(for subtype: PDFAnnotationSubtype) -> String {
    if subtype == .highlight { return "Highlight" }
    if subtype == .underline { return "Underline" }
    return ""
  }

  func forceClearSelection() {
    setCurrentSelection(nil, animate: false)
    clearSelection()
  }

  func refreshAutoSavePreference() {
    forceClearSelection()
    clearLookupHighlight(immediate: true)
    documentView?.setNeedsLayout()
    documentView?.layoutIfNeeded()
    documentView?.setNeedsDisplay()
    setNeedsLayout()
    layoutIfNeeded()
    setNeedsDisplay()
    reloadInputViews()
  }

  func showLookupHighlight(rect: CGRect, rectOnPage: CGRect? = nil, page: PDFPage? = nil) {
    guard rect.isNull == false, rect.isEmpty == false else { return }
    lookupHighlightRectOnPage = rectOnPage
    lookupHighlightPage = page
    registerScaleObserverIfNeeded()
    let container: UIView = documentView ?? self

    let view: UIView
    if let existing = lookupHighlightView {
      view = existing
    } else {
      let highlight = UIView()
      highlight.tag = Self.lookupHighlightTag
      highlight.isUserInteractionEnabled = false
      let customFill: UIColor?
      let customStroke: UIColor?
      if SubscriptionManager.shared.isEffectivelyPremium,
         let hex = UserDefaults.standard.string(forKey: "customHighlightColorHex"),
         let base = UIColor(highlightHex: hex) {
          customFill = base.withAlphaComponent(0.24)
          customStroke = base.withAlphaComponent(0.45)
      } else {
          customFill = nil
          customStroke = nil
      }
      highlight.backgroundColor = customFill
        ?? (ReaderVisualStyleMode.current.isRefined
            ? ReaderRefinedPalette.lookupHighlightFill
            : UIColor.systemYellow.withAlphaComponent(0.22))
      highlight.layer.borderWidth = 1
      highlight.layer.borderColor = (customStroke
        ?? (ReaderVisualStyleMode.current.isRefined
            ? ReaderRefinedPalette.lookupHighlightStroke
            : UIColor.systemYellow.withAlphaComponent(0.45))).cgColor
      highlight.layer.cornerRadius = ReaderVisualStyleMode.current.isRefined ? 8 : 4
      highlight.layer.masksToBounds = true
      highlight.alpha = 0
      lookupHighlightView = highlight

      container.addSubview(highlight)
      view = highlight
    }

    if view.superview !== container {
      view.removeFromSuperview()
      container.addSubview(view)
    }

    let padded = rect.insetBy(dx: -2, dy: -1).integral
    let containerRect = container.convert(padded, from: self)
    view.frame = containerRect
    container.bringSubviewToFront(view)
    view.layer.removeAllAnimations()

    UIView.animate(
      withDuration: 0.12, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]
    ) {
      view.alpha = 1
    }
  }

  private func removeTaggedSubviews(in view: UIView) {
    for subview in view.subviews {
      if subview.tag == Self.lookupHighlightTag {
        subview.removeFromSuperview()
        continue
      }
      removeTaggedSubviews(in: subview)
    }
  }

  func clearLookupHighlight(immediate: Bool = false) {
    lookupHighlightRectOnPage = nil
    lookupHighlightPage = nil
    if let scaleObserver {
      NotificationCenter.default.removeObserver(scaleObserver)
      self.scaleObserver = nil
    }
    let containers = [documentView, self].compactMap { $0 }
    let tagged = containers.flatMap { container in
      container.subviews.filter { $0.tag == Self.lookupHighlightTag }
    }

    // If we lost the strong reference (or multiple views were created), ensure cleanup anyway.
    if let view = lookupHighlightView {
      lookupHighlightView = nil
      tagged.filter { $0 !== view }.forEach { $0.removeFromSuperview() }
      if immediate {
        view.alpha = 0
        view.removeFromSuperview()
      } else {
        UIView.animate(
          withDuration: 0.12, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]
        ) {
          view.alpha = 0
        } completion: { _ in
          view.removeFromSuperview()
        }
      }
    } else {
      tagged.forEach { $0.removeFromSuperview() }
    }

    // Extra safety: in page-view-controller mode, the highlight can live under nested containers.
    removeTaggedSubviews(in: self)
    if let documentView {
      removeTaggedSubviews(in: documentView)
    }
    if let superview {
      removeTaggedSubviews(in: superview)
    }
    if let window {
      removeTaggedSubviews(in: window)
    }
  }

  private func registerScaleObserverIfNeeded() {
    guard scaleObserver == nil else { return }
    scaleObserver = NotificationCenter.default.addObserver(
      forName: .PDFViewScaleChanged, object: self, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.refreshLookupHighlightFrame()
      }
    }
  }

  private func refreshLookupHighlightFrame() {
    guard
      let view = lookupHighlightView,
      let rectOnPage = lookupHighlightRectOnPage,
      let page = lookupHighlightPage
    else { return }
    let converted = convert(rectOnPage, from: page)
    guard converted.isNull == false, converted.isEmpty == false else { return }
    let padded = converted.insetBy(dx: -2, dy: -1).integral
    let container: UIView = documentView ?? self
    let containerRect = container.convert(padded, from: self)
    view.frame = containerRect
  }
}

@MainActor
@preconcurrency
private final class PDFDrawingOverlayProvider: NSObject, PDFPageOverlayViewProvider,
  PKCanvasViewDelegate
{
  private weak var pdfView: PDFView?
  private final class WeakCanvas {
    weak var canvas: PKCanvasView?

    init(_ canvas: PKCanvasView?) {
      self.canvas = canvas
    }
  }

  private var visibleCanvasByPageIndex: [Int: WeakCanvas] = [:]
  private var pageIndexByCanvasID: [ObjectIdentifier: Int] = [:]
  private var drawingDataByPageIndex: [Int: Data] = [:]
  private var isEnabled: Bool = false
  private var isVisible: Bool = true
  private var drawingBookId: String?
  private var pendingPersistByPageIndex: [Int: DispatchWorkItem] = [:]

  private var currentTool: PKTool = PKInkingTool(.pen, color: .systemBlue, width: 3.4)

  func attach(to pdfView: PDFView) {
    self.pdfView = pdfView
  }

  func setBookId(_ bookId: String) {
    guard !bookId.isEmpty else { return }
    guard drawingBookId != bookId else { return }

    flushAllPendingPersist()
    drawingBookId = bookId
    drawingDataByPageIndex = BookDrawingStore.shared.load(bookId: bookId)

    for (pageIndex, weakCanvas) in visibleCanvasByPageIndex {
      guard let canvas = weakCanvas.canvas else { continue }
      applyDrawing(to: canvas, pageIndex: pageIndex)
    }
  }

  func setEnabled(_ enabled: Bool) {
    isEnabled = enabled
    visibleCanvases().forEach { canvas in
      canvas.isUserInteractionEnabled = enabled && isVisible
      canvas.drawingPolicy = .anyInput
      canvas.isHidden = !isVisible
    }
  }

  func setVisible(_ visible: Bool) {
    isVisible = visible
    visibleCanvases().forEach { canvas in
      canvas.isHidden = !visible
      canvas.isUserInteractionEnabled = isEnabled && visible
    }
  }

  func setInkTool(
    _ kind: ReadTapPDFView.DrawingInkKind,
    color: UIColor,
    widthPreset: ReadTapPDFView.DrawingWidthPreset = .medium
  ) {
    let tool: PKInkingTool
    switch kind {
    case .pen:
      tool = PKInkingTool(.pen, color: color, width: inkWidth(for: kind, preset: widthPreset))
    case .highlighter:
      tool = PKInkingTool(
        .marker,
        color: color.withAlphaComponent(0.9),
        width: inkWidth(for: kind, preset: widthPreset)
      )
    }
    currentTool = tool
    visibleCanvases().forEach { $0.tool = tool }
  }

  func setEraser(_ kind: ReadTapPDFView.DrawingEraserKind) {
    let eraserType: PKEraserTool.EraserType = (kind == .partial) ? .bitmap : .vector
    let tool = PKEraserTool(eraserType)
    currentTool = tool
    visibleCanvases().forEach { $0.tool = tool }
  }

  func undo() {
    guard let canvas = currentCanvas() else { return }
    canvas.undoManager?.undo()
    persistDrawing(from: canvas, immediate: false)
  }

  func redo() {
    guard let canvas = currentCanvas() else { return }
    canvas.undoManager?.redo()
    persistDrawing(from: canvas, immediate: false)
  }

  private func inkWidth(
    for kind: ReadTapPDFView.DrawingInkKind,
    preset: ReadTapPDFView.DrawingWidthPreset
  ) -> CGFloat {
    switch (kind, preset) {
    case (.pen, .thin):
      return 2.2
    case (.pen, .medium):
      return 3.4
    case (.pen, .bold):
      return 4.8
    case (.highlighter, .thin):
      return 10.0
    case (.highlighter, .medium):
      return 14.0
    case (.highlighter, .bold):
      return 18.0
    }
  }

  private func currentCanvas() -> PKCanvasView? {
    guard let pdfView, let page = pdfView.currentPage else { return nil }
    let pageIndex = page.document?.index(for: page) ?? -1
    guard pageIndex >= 0 else { return nil }
    return visibleCanvasByPageIndex[pageIndex]?.canvas
  }

  private func visibleCanvases() -> [PKCanvasView] {
    visibleCanvasByPageIndex = visibleCanvasByPageIndex.filter { $0.value.canvas != nil }
    return visibleCanvasByPageIndex.values.compactMap { $0.canvas }
  }

  func refreshVisibleCanvases() {
    for (pageIndex, weakCanvas) in visibleCanvasByPageIndex {
      guard let canvas = weakCanvas.canvas else { continue }
      canvas.isHidden = !isVisible
      canvas.isUserInteractionEnabled = isEnabled && isVisible
      canvas.drawingPolicy = .anyInput
      canvas.tool = currentTool
      applyDrawing(to: canvas, pageIndex: pageIndex)
    }
  }

  func hasCanvasForCurrentPage() -> Bool {
    guard let pdfView, let page = pdfView.currentPage else { return false }
    let pageIndex = page.document?.index(for: page) ?? -1
    guard pageIndex >= 0 else { return false }
    return visibleCanvasByPageIndex[pageIndex]?.canvas != nil
  }

  func pdfView(_ view: PDFView, overlayViewFor page: PDFPage) -> UIView? {
    let canvas = PKCanvasView(frame: .zero)
    canvas.backgroundColor = .clear
    canvas.isOpaque = false
    canvas.drawingPolicy = .anyInput
    canvas.delegate = self
    canvas.tool = currentTool
    canvas.isUserInteractionEnabled = isEnabled && isVisible
    canvas.isHidden = !isVisible

    if let pageIndex = page.document?.index(for: page) {
      pageIndexByCanvasID[ObjectIdentifier(canvas)] = pageIndex
      visibleCanvasByPageIndex[pageIndex] = WeakCanvas(canvas)
      applyDrawing(to: canvas, pageIndex: pageIndex)
    }

    return canvas
  }

  func pdfView(_ view: PDFView, willDisplayOverlayView overlayView: UIView, for page: PDFPage) {
    guard let canvas = overlayView as? PKCanvasView else { return }
    canvas.isUserInteractionEnabled = isEnabled && isVisible
    canvas.drawingPolicy = .anyInput
    canvas.isHidden = !isVisible
    canvas.tool = currentTool
    if let pageIndex = page.document?.index(for: page) {
      visibleCanvasByPageIndex[pageIndex] = WeakCanvas(canvas)
      pageIndexByCanvasID[ObjectIdentifier(canvas)] = pageIndex
      applyDrawing(to: canvas, pageIndex: pageIndex)
    }
  }

  func pdfView(_ view: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage)
  {
    guard let canvas = overlayView as? PKCanvasView else { return }
    guard let pageIndex = page.document?.index(for: page) else { return }
    drawingDataByPageIndex[pageIndex] = canvas.drawing.dataRepresentation()
    persist(pageIndex: pageIndex, immediate: true)
    if visibleCanvasByPageIndex[pageIndex]?.canvas === canvas {
      visibleCanvasByPageIndex.removeValue(forKey: pageIndex)
    }
    pageIndexByCanvasID.removeValue(forKey: ObjectIdentifier(canvas))
  }

  func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
    persistDrawing(from: canvasView, immediate: false)
  }

  private func applyDrawing(to canvas: PKCanvasView, pageIndex: Int) {
    if let data = drawingDataByPageIndex[pageIndex], let drawing = try? PKDrawing(data: data) {
      canvas.drawing = drawing
    } else if !canvas.drawing.strokes.isEmpty {
      canvas.drawing = PKDrawing()
    }
  }

  private func persistDrawing(from canvas: PKCanvasView, immediate: Bool) {
    let key = ObjectIdentifier(canvas)
    guard let pageIndex = pageIndexByCanvasID[key] else { return }
    drawingDataByPageIndex[pageIndex] = canvas.drawing.dataRepresentation()
    persist(pageIndex: pageIndex, immediate: immediate)
  }

  private func persist(pageIndex: Int, immediate: Bool) {
    guard let bookId = drawingBookId else { return }
    let data = drawingDataByPageIndex[pageIndex]

    pendingPersistByPageIndex[pageIndex]?.cancel()
    pendingPersistByPageIndex[pageIndex] = nil

    let save: () -> Void = {
      BookDrawingStore.shared.save(bookId: bookId, pageIndex: pageIndex, drawingData: data)
    }

    if immediate {
      save()
      return
    }

    let work = DispatchWorkItem(block: save)
    pendingPersistByPageIndex[pageIndex] = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
  }

  private func flushAllPendingPersist() {
    for (_, work) in pendingPersistByPageIndex {
      work.cancel()
    }
    pendingPersistByPageIndex.removeAll()
  }

  func flushPendingPersistNow() {
    let pageIndexes = Set(pendingPersistByPageIndex.keys)
    flushAllPendingPersist()
    for pageIndex in pageIndexes {
      persist(pageIndex: pageIndex, immediate: true)
    }
    if let currentCanvas = currentCanvas() {
      persistDrawing(from: currentCanvas, immediate: true)
    }
  }
}
