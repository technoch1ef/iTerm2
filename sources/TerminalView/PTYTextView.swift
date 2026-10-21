//
//  PTYTextView.swift
//  iTerm2SharedARC
//
//  Created by George Nachman on 4/13/22.
//

import Foundation
import UniformTypeIdentifiers
import WebKit

// Posted when lines are shifted by fold/unfold. object is the session GUID (String).
// userInfo keys: absLineKey (NSNumber Int64), deltaKey (NSNumber Int64, positive=insert, negative=remove).
@objc(iTermLinesShiftedNotification) class LinesShiftedNotification: NSObject {
    @objc static let name = NSNotification.Name("iTermLinesWereShifted")
    @objc static let absLineKey = "absLine"
    @objc static let deltaKey = "delta"
    @objc static let markKey = "mark"
    @objc static let reasonKey = "reason"
    /// NSValue wrapping NSRange. The range of absolute lines that was replaced.
    @objc static let replacedRangeKey = "replacedRange"
    /// Block: (VT100GridCoord) -> VT100GridCoord. Converts a coord relative to
    /// the start of the replaced range from the old layout to the new layout.
    /// Returns (-1,-1) if the coord can't be converted.
    @objc static let converterKey = "converter"
}


extension VT100GridAbsCoordRange {
    func relativeRange(overflow: Int64) -> VT100GridCoordRange {
        return VT100GridCoordRangeFromAbsCoordRange(self, overflow)
    }
}

extension VT100GridCoordRange {
    var windowedWithDefaultWindow: VT100GridWindowedRange {
        return VT100GridWindowedRangeMake(self, 0, 0)
    }
}

extension PTYTextView: ExternalSearchResultsController {
    private var portholeWithSelection: Porthole? {
        return typedPortholes.first { $0.hasSelection }
    }

    @objc var anyPortholeHasSelection: Bool {
        return portholeWithSelection != nil
    }

    @objc func copyFromPortholeAsPlainText() {
        portholeWithSelection?.copy(as: .plainText)
    }

    @objc func copyFromPortholeAsAttributedString() {
        portholeWithSelection?.copy(as: .attributedString)
    }

    @objc func copyFromPortholeWithControlSequences() {
        portholeWithSelection?.copy(as: .controlSequences)
    }

    @objc(renderRange:type:filename:forceWide:)
    func render(range originalRange: VT100GridAbsCoordRange,
                type: String?,
                filename: String?,
                forceWide: Bool) {
        DLog("render(range:\(VT100GridAbsCoordRangeDescription(originalRange)), type:\(String(describing: type)), filename:\(String(describing: filename)))")
        guard let dataSource = dataSource else {
            DLog("nil datasource")
            return
        }
        var absRange = originalRange
        let overflow = dataSource.totalScrollbackOverflow()
        let width = dataSource.width()
        let relativeRange = absRange.relativeRange(overflow: overflow)
        absRange.start.x = 0
        if absRange.end.x > 0 {
            absRange.end.x = width
        }
        let text = self.text(inRange: absRange.relativeRange(overflow: overflow))
        let pwd = dataSource.workingDirectory(onLine: relativeRange.start.y)
        let baseDirectory = pwd.map { URL(fileURLWithPath: $0) }
        replaceWithPorthole(inRange: absRange,
                            text: text,
                            baseDirectory: baseDirectory,
                            type: type,
                            filename: filename,
                            forceWide: forceWide)
    }

    func text(inRange range: VT100GridCoordRange) -> String {
        DLog("text(inRange:\(VT100GridCoordRangeDescription(range))")
        let extractor = iTermTextExtractor(dataSource: dataSource)
        let windowedRange = range.windowedWithDefaultWindow
        let text = extractor.content(in: windowedRange,
                                     attributeProvider: nil,
                                     nullPolicy: .kiTermTextExtractorNullPolicyMidlineAsSpaceIgnoreTerminal,
                                     pad: false,
                                     includeLastNewline: false,
                                     trimTrailingWhitespace: false,
                                     cappedAtSize: -1,
                                     truncateTail: false,
                                     continuationChars: nil,
                                     coords: nil,
                                     deduplicateDECDHL: true) as! String
        DLog("Return \(text)")
        return text
    }

    @objc(replaceWithPortholeInRange:havingText:baseDirectory:type:filename:forceWide:)
    func replaceWithPorthole(inRange absRange: VT100GridAbsCoordRange,
                             text: String,
                             baseDirectory: URL?,
                             type: String?,
                             filename: String?,
                             forceWide: Bool) {
        DLog("replaceWithPorthole(inRange:\(VT100GridAbsCoordRangeDescription(absRange)), text:\(String(describing: text)), baseDirectory:\(String(describing: baseDirectory)), type:\(String(describing: type)), filename:\(String(describing: filename))")

        guard dataSource != nil else {
            DLog("nil dataSource")
            return
        }
        let config = PortholeConfig(text: text,
                                    colorMap: colorMap,
                                    baseDirectory: baseDirectory,
                                    font: self.fontTable.asciiFont.font,
                                    type: type,
                                    filename: filename,
                                    useSelectedTextColor: delegate?.textViewShouldUseSelectedTextColor() ?? true,
                                    forceWide: iTermAdvancedSettingsModel.defaultWideMode() || forceWide)
        let porthole = makePorthole(for: config)
        replace(range: absRange, withPorthole: porthole)
    }

    private func replace(range absRange: VT100GridAbsCoordRange,
                         withPorthole porthole: Porthole) {
        DLog("replace(range:\(VT100GridAbsCoordRangeDescription(absRange)), withPorthole:\(porthole))")
        let hmargin = CGFloat(iTermPreferences.sideMargins())
        let desiredHeight = porthole.fit(toWidth: bounds.width - hmargin * 2)
        let relativeRange = VT100GridCoordRangeFromAbsCoordRange(absRange, dataSource.totalScrollbackOverflow())
        porthole.savedLines = (relativeRange.start.y ... relativeRange.end.y).map { i in
            dataSource.screenCharArray(forLine: i).copy() as! ScreenCharArray
        }
        dataSource.replace(absRange, with: porthole, ofHeight: Int32(ceil(desiredHeight / lineHeight)))
    }

    private func makePorthole(for config: PortholeConfig) -> Porthole {
        DLog("makePorthole(for:\(config)")
        return configuredPorthole(PortholeFactory.textViewPorthole(config: config))
    }

    private func configuredPorthole(_ porthole: Porthole) -> Porthole {
        DLog("configurePorthole(\(porthole))")
        if let textPorthole = porthole as? TextViewPorthole {
            textPorthole.changeLanguageCallback = { [weak self] language, porthole in
                guard let self = self else {
                    return
                }
                self.layoutPorthole(porthole)
            }
        }
        return porthole
    }

    private func layoutPorthole(_ porthole: Porthole) {
        DLog("layoutPorthole(\(porthole))")
        guard let dataSource = dataSource else {
            return
        }
        let hmargin = CGFloat(iTermPreferences.sideMargins())
        let desiredHeight = porthole.fit(toWidth: bounds.width - hmargin * 2)
        dataSource.changeHeight(of: porthole.mark, to: Int32(ceil(desiredHeight / lineHeight)))
    }

    @objc
    func addPorthole(_ objcPorthole: ObjCPorthole) {
        DLog("addPorthole(\(objcPorthole))")
        let porthole = objcPorthole as! Porthole
        portholes.add(porthole)
        addPortholeView(porthole)
    }

    @objc func hydratePorthole(_ mark: PortholeMarkReading) -> ObjCPorthole? {
        RLog("hydratePorthole(\(mark))")
        guard let interval = mark.entry?.interval,
              let absRange = dataSource?.absCoordRange(for: interval) else {
            return nil
        }
        guard let porthole = PortholeRegistry.instance.get(mark.uniqueIdentifier,
                                                           colorMap: colorMap,
                                                           useSelectedTextColor: delegate?.textViewShouldUseSelectedTextColor() ?? true,
                                                           font: self.fontTable.asciiFont.font) as? Porthole else {
            return nil
        }
        // If there were any annotations, fix their delegate pointer up.
        dataSource?.add(porthole.savedITOs, baseLine: absRange.start.y)
        return configuredPorthole(porthole)
    }

    private func addPortholeView(_ porthole: Porthole) {
        DLog("addPortholeView(\(porthole))")
        porthole.delegate = self
        // I'd rather add it to TextViewWrapper but doing so somehow causes TVW to be overreleased
        // and I can't figure out why.
        addSubview(porthole.view)
        updatePortholeFrame(porthole, force: true)
        NotificationCenter.default.post(name: NSNotification.Name.iTermPortholesDidChange, object: nil)
        requestDelegateRedraw()
        porthole.view.needsDisplay = true
        self.delegate?.textViewDidAddOrRemovePorthole()
    }

    // Continue owning the porthole but remove it from view.
    @objc
    func hidePorthole(_ objcPorthole: ObjCPorthole) {
        DLog("hidePorthole(\(objcPorthole))")
        let porthole = objcPorthole as! Porthole
        willRemoveSubview(porthole.view)
        if porthole.delegate === self {
            porthole.delegate = nil
        }
        Self.removePortholeViewWithoutAnimation(porthole.view)
        NotificationCenter.default.post(name: NSNotification.Name.iTermPortholesDidChange, object: nil)
        self.delegate?.textViewDidAddOrRemovePorthole()
    }

    // Reclaim a porthole that was hidden (e.g. folded) and whose fold was then
    // permanently removed without going through unfold (Clear Buffer, scrollback
    // overflow). prunePortholes deliberately skips hidden portholes since it
    // can't tell "will return via unfold" from "gone forever"; the destruction
    // site knows, and signals here.
    @objc(forciblyRemovePortholeWithUniqueIdentifier:)
    func forciblyRemovePorthole(uniqueIdentifier: String) {
        RLog("forciblyRemovePorthole(\(uniqueIdentifier))")
        // Drop the registry references unconditionally. This is the whole point
        // of the signal: break the doppelganger retain cycle (registry -> mark
        // doppelganger -> progenitor) so the progenitor mark carried in the
        // destroyed fold's savedITOs can deinit. It must run even when no view
        // was ever hydrated into `portholes` (e.g. a session restored with the
        // region already folded, then cleared before it was displayed), because
        // then there is nothing else that will ever free it.
        PortholeRegistry.instance.remove(uniqueIdentifier)
        guard let index = typedPortholes.firstIndex(where: { $0.uniqueIdentifier == uniqueIdentifier }) else {
            return
        }
        let porthole = typedPortholes[index]
        Self.removePortholeViewWithoutAnimation(porthole.view)
        portholes.removeObject(at: index)
    }

    // The porthole container is layer-backed, so a plain removeFromSuperview
    // plays Core Animation's implicit order-out fade. That looks wrong when a
    // porthole goes away as part of folding or clearing, where the surrounding
    // text disappears instantly. Suppress the implicit action so it matches.
    private static func removePortholeViewWithoutAnimation(_ view: NSView) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.removeFromSuperview()
        CATransaction.commit()
    }

    @objc
    func unhidePorthole(_ objcPorthole: ObjCPorthole) {
        DLog("unhidePorthole(\(objcPorthole))")
        let porthole = objcPorthole as! Porthole
        guard portholes.contains(porthole) else {
            RLog("Not unhiding porthole we don't own")
            return
        }
        guard porthole.view.superview != self else {
            DLog("Porthole is already shown; nothing to unhide")
            return
        }
        addPortholeView(porthole)
    }

    @objc
    func removePorthole(_ objcPorthole: ObjCPorthole) {
        RLog("removePorthole(\(objcPorthole))")
        let porthole = objcPorthole as! Porthole
        willRemoveSubview(porthole.view)
        if porthole.delegate === self {
            porthole.delegate = nil
        }
        portholes.remove(porthole)
        porthole.view.removeFromSuperview()
        if let mark = PortholeRegistry.instance.mark(for: porthole.uniqueIdentifier) {
            dataSource?.replace(mark, withLines: porthole.savedLines, savedITOs: porthole.savedITOs)
        }
        NotificationCenter.default.post(name: NSNotification.Name.iTermPortholesDidChange, object: nil)
        self.delegate?.textViewDidAddOrRemovePorthole()
    }

    @objc
    func updatePortholeFrames() {
        DLog("Begin updatePortholeFrames")
        for porthole in portholes {
            updatePortholeFrame(porthole as! Porthole, force: false)
        }
        updateInlineWebViewFrames()
        DLog("End updatePortholeFrames")
    }

    @objc(stringForPortholeInRange:)
    func stringForPorthole(range: VT100GridCoordRange) -> String? {
        for obj in portholes {
            let porthole = obj as! Porthole
            guard let gridCoordRange = self.range(porthole: porthole) else {
                continue
            }
            if range.start.y < gridCoordRange.end.y && range.end.y > gridCoordRange.start.y {
                return porthole.savedLines.map {
                    $0.stringValue
                }.joined(separator: "\n")
            }
        }
        return nil
    }

    private func range(porthole: Porthole) -> VT100GridCoordRange? {
        DLog("range(porthole: \(porthole))")
        guard PortholeRegistry.instance.mark(for: porthole.uniqueIdentifier) != nil else {
            return nil
        }
        guard let dataSource = dataSource else {
            return nil
        }
        let gridCoordRange = dataSource.coordRange(of: porthole)
        guard gridCoordRange != VT100GridCoordRangeInvalid else {
            return nil
        }
        guard gridCoordRange.start.y <= gridCoordRange.end.y else {
            return nil
        }
        DLog("return \(VT100GridCoordRangeDescription(gridCoordRange))")
        return gridCoordRange
    }

    // If force is true, recalculate the height even if the textview's width hasn't changed since
    // the last time this method was called.
    private func updatePortholeFrame(_ objcPorthole: ObjCPorthole, force: Bool) {
        DLog("updatePortholeFrame(\(objcPorthole)")
        let porthole = objcPorthole as! Porthole
        guard let dataSource = dataSource else {
            DLog("nil datasource")
            return
        }
        guard let gridCoordRange = range(porthole: porthole) else {
            DLog("no range")
            return
        }
        let lineRange = gridCoordRange.start.y...gridCoordRange.end.y
        DLog("Update porthole with line range \(lineRange)")
        let hmargin = CGFloat(iTermPreferences.sideMargins())
        let vmargin = CGFloat(iTermPreferences.topBottomMargins())
        let cellWidth = dataSource.width()
        let innerMargin = porthole.outerMargin
        if lastPortholeWidth == cellWidth && !force {
            // Calculating porthole size is very slow because NSView is a catastrophe so avoid doing
            // it if the width is unchanged.
            let y = CGFloat(lineRange.lowerBound) * lineHeight + vmargin + innerMargin
            DLog("y=\(y) range=\(String(describing: VT100GridCoordRangeDescription(gridCoordRange ))) overflow=\(dataSource.scrollbackOverflow())")
            porthole.set(frame: NSRect(x: hmargin,
                                       y: y,
                                       width: bounds.width - hmargin * 2,
                                       height: CGFloat(lineRange.count) * lineHeight - innerMargin * 2))
        } else {
            lastPortholeWidth = cellWidth
            porthole.set(frame: NSRect(x: hmargin,
                                       y: CGFloat(lineRange.lowerBound) * lineHeight + vmargin + innerMargin,
                                       width: bounds.width - hmargin * 2,
                                       height: CGFloat(lineRange.count) * lineHeight - innerMargin * 2))
        }
        updateAlphaValue()
    }

    @objc
    var hasPortholes: Bool {
        // Inline web views are subviews too, so they need the same non-Metal/alpha treatment.
        return portholes.count > 0 || !inlineWebViews.isEmpty
    }

    // Because Swift can't cope with forward declarations and I don't want a dependency cycle.
    private var typedPortholes: [Porthole] {
        return portholes as! [Porthole]
    }

    @objc
    func removePortholeSelections() {
        DLog("removePortholeSelections")
        for porthole in typedPortholes {
            porthole.removeSelection()
        }
    }

    @objc
    func removePortholeHighlights() {
        for porthole in typedPortholes {
            porthole.removeHighlights()
        }
    }

    @objc(removePortholeHighlightsFrom:)
    func removePortholeHighlights(from externalSearchResult: ExternalSearchResult) {
        externalSearchResult.owner?.remove(externalSearchResult)
    }


    @objc
    func updatePortholeColors(useSelectedTextColor: Bool, deferUpdate: Bool) {
        DLog("updatePortholeColors(useSelectedTextColor: \(useSelectedTextColor))")
        for porthole in typedPortholes {
            porthole.updateColors(useSelectedTextColor: useSelectedTextColor,
                                  deferUpdate: deferUpdate)
        }
    }

    @objc
    func absRangeIntersectsPortholes(_ absRange: VT100GridAbsCoordRange) -> Bool {
        DLog("absRangeIntersectsPortholes(\(VT100GridAbsCoordRangeDescription(absRange)))")
        guard let dataSource = dataSource else {
            return false
        }
        let range = VT100GridCoordRangeFromAbsCoordRange(absRange, dataSource.totalScrollbackOverflow())
        for porthole in typedPortholes {
            let portholeRange = dataSource.coordRange(of: porthole)
            guard portholeRange != VT100GridCoordRangeInvalid else {
                continue
            }
            let lhs = portholeRange.start.y...portholeRange.end.y
            let rhs = range.start.y...range.end.y
            if lhs.overlaps(rhs) {
                return true
            }
        }
        return false
    }

    @objc(setNeedsPrunePortholes:)
    func setNeedsPrunePortholes(_ needs: Bool) {
        DLog("setNeedsPrunePortholes(\(needs))")
        if self.portholesNeedUpdatesJoiner == nil {
            self.portholesNeedUpdatesJoiner = IdempotentOperationJoiner.asyncJoiner(.main)
        }
        self.portholesNeedUpdatesJoiner.setNeedsUpdate { [weak self] in
            self?.prunePortholes()
        }
    }
    @objc
    func prunePortholes() {
        DLog("prunePortholes")
        let registry = PortholeRegistry.instance
        let indexes = typedPortholes.indexes { porthole in
            // Folded (and alt-screen-swapped) portholes are deliberately hidden:
            // their view is detached from the textview and their mark is retained
            // for restore. Never prune those; they come back via unhidePorthole.
            guard porthole.view.superview === self else {
                return false
            }
            // Otherwise a porthole should live only while its mark occupies a
            // valid location in the accessible interval tree. coordRange(of:)
            // returns invalid once the mark has been removed (Clear Buffer,
            // deletion, or scrolled into the dustbin). We key off this rather
            // than the registry mark being deallocated: the progenitor mark can
            // outlive its removal from the tree (it's retained via its
            // doppelganger), so waiting for dealloc would leave the view behind.
            let coordRange = dataSource?.coordRange(of: porthole) ?? VT100GridCoordRangeInvalid
            return coordRange == VT100GridCoordRangeInvalid
        }
        for i in indexes {
            let porthole = typedPortholes[i]
            Self.removePortholeViewWithoutAnimation(porthole.view)
            // Drop the registry's references too. Normally this happens when the
            // mark deinits, but that can be delayed indefinitely by the
            // doppelganger, which would leak the porthole and its saved lines.
            registry.remove(porthole.uniqueIdentifier)
        }
        portholes.removeObjects(at: indexes)
        DLog("done")
    }

    @objc
    func searchPortholes(for string: String, mode: iTermFindMode) -> [ExternalSearchResult] {
        var result = [ExternalSearchResult]()
        for porthole in typedPortholes {
            result.append(contentsOf: porthole.find(string, mode: mode))
        }
        return result
    }

    @objc(selectExternalSearchResult:multiple:scroll:)
    @discardableResult
    func select(externalSearchResult result: ExternalSearchResult,
                multiple: Bool,
                scroll: Bool) -> VT100GridCoordRange {
        let overflow = dataSource?.totalScrollbackOverflow() ?? 0
        let y = Int32(result.absLine - overflow)
        if let porthole = self.porthole(for: result),
           let rect = porthole.select(searchResult: result,
                                      multiple: multiple,
                                      returningRectRelativeTo: self,
                                      scroll: scroll) {
            if scroll {
                // This is necessary when there's a horizontally scrolling scrollview in the porthole
                // in order to make PTYScrollView move vertically.
                let line = Int32(rect.midY / lineHeight)
                self.scroll(toCenterLine: line)
                (enclosingScrollView?.verticalScroller as? PTYScroller)?.userScroll = true
            }
            return VT100GridCoordRange(
                start: VT100GridCoord(x: 0,
                                      y: y),
                end: VT100GridCoord(x: 0,
                                    y: y + Int32(floor(rect.height / lineHeight))))
        } else {
            return VT100GridCoordRange(start: VT100GridCoord(x: 0, y: y),
                                       end: VT100GridCoord(x: 0, y: y + result.numLines))
        }
    }

    @objc func externalSearchResults(for query: String, mode: iTermFindMode) -> [ExternalSearchResult] {
        return typedPortholes.flatMap { porthole in
            porthole.find(query, mode: mode)
        }
    }
    func snippet(from result: ExternalSearchResult,
                 matchAttributes: [NSAttributedString.Key : Any],
                 regularAttributes: [NSAttributedString.Key : Any]) -> NSAttributedString? {
        return porthole(for: result)?.snippet(for: result,
                                              matchAttributes: matchAttributes,
                                              regularAttributes: regularAttributes)
    }


    private func porthole(for result: ExternalSearchResult) -> Porthole? {
        guard let owner = result.owner else {
            return nil
        }
        guard let i = typedPortholes.firstIndex(where: { $0 === owner }) else {
            return nil
        }
        return typedPortholes[i]
    }

    // MARK: - Marks

    @objc(foldMarkAtWindowCoord:)
    func foldMark(at windowCoord: NSPoint) -> FoldMarkReading? {
        guard let dataSource = dataSource else {
            return nil
        }
        let locationInTextView = convert(windowCoord, from: nil)
        if Int(clamping: locationInTextView.x) >= iTermPreferences.sideMargins() + Int32(PTYTextViewMarginClickGraceWidth) {
            return nil
        }
        let coord = self.coord(for: locationInTextView, allowRightMarginOverflow: true)
        if coord.y < 0 {
            return nil
        }
        let marks = dataSource.foldMarks(in: VT100GridRange(location: coord.y, length: 1))
        return marks?.first
    }

    @objc(commandMarkAtWindowCoord:)
    func commandMark(at windowCoord: NSPoint) -> VT100ScreenMarkReading? {
        let locationInTextView = convert(windowCoord, from: nil)
        if Int(clamping: locationInTextView.x) >= iTermPreferences.sideMargins() {
            return nil
        }
        let coord = self.coord(for: locationInTextView, allowRightMarginOverflow: true)
        if coord.y < 0 {
            return nil
        }
        return dataSource?.commandMark(at: VT100GridCoord(x: 0, y: coord.y),
                                      mustHaveCommand: true,
                                      range: nil)
    }

    @objc(pathMarkAtWindowCoord:)
    func pathMark(at windowCoord: NSPoint) -> PathMarkReading? {
        let locationInTextView = convert(windowCoord, from: nil)
        if Int(clamping: locationInTextView.x) < iTermPreferences.sideMargins() {
            return nil
        }
        guard let dataSource = dataSource else {
            return nil
        }
        let coord = self.coord(for: locationInTextView, allowRightMarginOverflow: true)
        if coord.y < 0 {
            return nil
        }
        return dataSource.pathMark(at: coord)
    }

    // MARK: - Folding

    @objc(toggleFoldSelectionAbsoluteLines:)
    func toggleFold(nsrange: NSRange) {
        guard let range = Range<Int64>(nsrange) else {
            return
        }
        guard let dataSource else {
            return
        }
        // If we can remove folds in this range, do so and don't continue.
        if dataSource.removeFolds(in: nsrange, completion: nil) {
            requestDelegateRedraw()
            return
        }
        let promptLength = self.promptLength(at: range.lowerBound)
        fold(range: range, promptLength: Int(promptLength))
    }

    @objc(unfoldAbsoluteLineRange:)
    func unfold(nsrange: NSRange) {
        guard Range<Int64>(nsrange) != nil else {
            return
        }
        guard let dataSource else {
            return
        }
        // If we can remove folds in this range, do so and don't continue.
        if dataSource.removeFolds(in: nsrange, completion: nil) {
            requestDelegateRedraw()
            return
        }
    }

    @objc(foldRange:)
    func fold(nsrange: NSRange) {
        guard let range = Range<Int64>(nsrange) else {
            return
        }
        let promptLength = self.promptLength(at: range.lowerBound)
        fold(range: range, promptLength: Int(promptLength))
    }

    private func promptLength(at absY: Int64) -> Int32 {
        var result: Int32 = 0
        withRelativeCoord(VT100GridAbsCoord(x: 0, y: absY)) { coord in
            if let mark = dataSource?.commandMark(at: coord, mustHaveCommand: true, range: nil),
               mark.promptRange.start.y == absY {
                result = mark.promptRange.height
            }
        }
        return result

    }
    private func fold(range: Range<Int64>,
                      promptLength: Int) {
        guard let dataSource else {
            return
        }
        RLog("Fold")
        let overflow = dataSource.totalScrollbackOverflow()
        let absRange = VT100GridAbsCoordRange(start: VT100GridAbsCoord(x: 0,
                                                                       y: range.lowerBound),
                                              end: VT100GridAbsCoord(x: dataSource.width(),
                                                                     y: range.upperBound - 1))
        let firstLine = dataSource.screenCharArray(forLine: Int32(max(0, range.lowerBound - overflow)))
        let lastLine = dataSource.screenCharArray(forLine: Int32(max(0, range.upperBound - 1 - overflow)))
        let line = firstEllipsisLast(firstLine, lastLine, length: dataSource.width(), count: Int(absRange.end.y - absRange.start.y) - 1)

        let blockMarks = dataSource.blockMarkDictionary(onLine: absRange.start.y)
        dataSource.replace(absRange,
                           withLines: [line.clone()],
                           promptLength: promptLength,
                           blockMarks: blockMarks)
        requestDelegateRedraw()
        didFoldOrUnfold()
    }

    // Make a display line that summarizes a folded region as [first line prefix] [ellipsis] [last line prefix].
    private func firstEllipsisLast(_ first: ScreenCharArray,
                                   _ untrimmedLast: ScreenCharArray,
                                   length: Int32,
                                   count: Int) -> ScreenCharArray {
        if length <= 0 {
            return ScreenCharArray.emptyLine(ofLength: 0)
        }
        let n = untrimmedLast.number(ofLeadingEmptyCellsWhereSpaceIsEmpty: true)
        let last = untrimmedLast.subArray(from: n)
        let firstMaxLength = first.length - first.number(ofTrailingEmptyCellsWhereSpaceIsEmpty: true)
        let lastMaxLength = last.length - last.number(ofTrailingEmptyCellsWhereSpaceIsEmpty: true)

        var mid = String(localized: "PTYTextView.MidLineCount", defaultValue: " …\(count) lines… ", comment: "Middle-of-range line count marker; %lld is the number of lines. Keep the surrounding ellipses and spaces.")
        if mid.utf16.count + 10 > length {
            mid = "…"
        }
        let midLength = Int32(mid.utf16.count)

        var firstLength = firstMaxLength
        var lastLength = lastMaxLength
        var overage = (firstLength + midLength + lastLength) - length
        while overage > 0 {
            if firstLength == lastLength {
                firstLength -= overage / 2
                lastLength -= (overage + 1) / 2  // round up if overage is odd so the total equals overage
            } else if firstLength > lastLength {
                firstLength -= min(firstLength - lastLength, overage)
            } else {
                lastLength -= (min(lastLength - firstLength, overage))
            }
            overage = (firstLength + midLength + lastLength) - length
        }
        let result = MutableScreenCharArray()

        // first
        result.append(first.paddedOrTruncated(toLength: UInt(firstLength)))

        // ellipsis
        result.append(mid, fg: screen_char_t(), bg: screen_char_t())

        // last
        result.append(last.paddedOrTruncated(toLength: UInt(lastLength)))

        // padding
        if overage < 0 {
            result.append(ScreenCharArray.emptyLine(ofLength: -overage))
        }

        var bg = screen_char_t()
        bg.backgroundColorMode = ColorModeAlternate.rawValue
        bg.backgroundColor = UInt32(ALTSEM_DEFAULT)
        result.setBackground(bg, in: NSRange(location: 0, length: Int(length)))

        var fg = screen_char_t()
        fg.foregroundColorMode = ColorModeAlternate.rawValue
        fg.foregroundColor = UInt32(ALTSEM_DEFAULT)
        fg.fgBlue = 0
        fg.fgGreen = 0
        fg.faint = 1
        fg.italic = 1
        result.setForeground(fg, in: NSRange(location: 0, length: Int(length)))
        result.setExternalAttributesIndex(first.eaIndex)

        var continuation = bg
        continuation.code = UInt16(EOL_HARD)
        result.continuation = continuation
        return result
    }

    @objc(unfoldMark:)
    func unfold(mark: FoldMarkReading) {
        unfold(mark: mark, completion: nil)
    }

    @objc(unfoldMark:completion:)
    func unfold(mark: FoldMarkReading, completion: ((Bool) -> ())?) {
        guard let interval = mark.entry?.interval else {
            completion?(false)
            return
        }
        guard let dataSource = dataSource else {
            completion?(false)
            return
        }
        RLog("Unfold")
        let coord = dataSource.absCoordRange(for: interval)
        dataSource.removeFolds(in: NSRange(location: Int(coord.start.y), length: 1),
                               completion: completion)
        requestDelegateRedraw()
        didFoldOrUnfold()
    }

    @objc(foldCommandMark:)
    func fold(commandMark: VT100ScreenMarkReading) {
        guard let dataSource = dataSource else {
            return
        }
        let range = dataSource.rangeOfCommandAndOutput(forMark: commandMark, includeSucessorDivider: false)
        fold(range: Range(range.start.y...range.end.y),
             promptLength: Int(commandMark.promptRange.height))
    }
}

extension Array {
    func indexes(where closure: (Element) throws -> Bool) rethrows -> IndexSet {
        var indexSet = IndexSet()
        for (i, element) in enumerated() {
            if try closure(element) {
                indexSet.insert(i)
            }
        }
        return indexSet
    }
}
extension PTYTextView: PortholeDelegate {
    func portholeDidAcquireSelection(_ porthole: Porthole) {
        DLog("portholeDidAcquireSelection")
        selection.clear()
        for other in typedPortholes {
            if porthole === other {
                continue
            }
            other.removeSelection()
        }
    }

    func portholeWantsFirstResponder(_ porthole: Porthole) {
        // Clicking inside a porthole should activate its split pane. The porthole's text view
        // refuses first responder, so make this text view first responder on its behalf.
        DLog("portholeWantsFirstResponder")
        window?.makeFirstResponder(self)
    }

    func portholeRemove(_ porthole: Porthole) {
        DLog("portholeRemove")
        removePorthole(porthole)
    }

    func portholeResize(_ porthole: Porthole) {
        layoutPorthole(porthole)
    }

    func portholeAbsLine(_ porthole: Porthole) -> Int64 {
        guard let dataSource = dataSource else {
            return -1
        }
        let range = dataSource.coordRange(of: porthole)
        if range == VT100GridCoordRangeInvalid {
            return -1
        }
        let absRange = VT100GridAbsCoordRangeFromCoordRange(
            range,
            dataSource.totalScrollbackOverflow())
        return absRange.start.y
    }

    func portholeHeight(_ porthole: Porthole) -> Int32 {
        guard let dataSource = dataSource else {
            return -1
        }
        let range = dataSource.coordRange(of: porthole)
        if range == VT100GridCoordRangeInvalid {
            return -1
        }
        return range.end.y - range.start.y + 1
    }
}

extension VT100GridCoordRange: Equatable {
    public static func == (lhs: VT100GridCoordRange, rhs: VT100GridCoordRange) -> Bool {
        return VT100GridCoordRangeEqualsCoordRange(lhs, rhs)
    }
}

extension PTYTextView {
    @objc
    func copySelectedCommand() {
        guard let mark = delegate?.textViewSelectedCommandMark() else {
            return
        }
        let selection = selectionForCommandAndOutput(ofMark: mark)
        copySelection(selection)
    }

    @objc
    func copySelectedCommandWithStyles() {
        guard let mark = delegate?.textViewSelectedCommandMark() else {
            return
        }
        let selection = selectionForCommandAndOutput(ofMark: mark)
        copySelection(withStyles: selection)
    }

    @objc
    func copySelectedCommandWithControlSequences() {
        guard let mark = delegate?.textViewSelectedCommandMark() else {
            return
        }
        let selection = selectionForCommandAndOutput(ofMark: mark)
        copySelection(withControlSequences: selection)
    }
}

extension PTYTextView: NSViewContentSelectionInfo {
    func clampedRelativeCoord(_ absCoord: VT100GridAbsCoord) -> VT100GridCoord {
        var result = VT100GridCoordMake(0, 0)
        withRelativeCoord(absCoord) { relative in
            result = relative
        }
        return result
    }

    func rect(for range: VT100GridAbsCoordRange) -> NSRect {
        let width = dataSource?.width() ?? 1
        let relativeStart = clampedRelativeCoord(range.start)
        let relativeEnd = clampedRelativeCoord(range.end)
        var coords = [relativeStart, relativeEnd]
        if relativeStart.y != relativeEnd.y {
            coords.append(VT100GridCoord(x: width - 1, y: relativeStart.y))
            coords.append(VT100GridCoord(x: 0, y: relativeEnd.y))
        }
        let rects = coords.map { rect(for: $0) }
        return rects.reduce(into: rects.first!) { partialResult, rect in
            partialResult = partialResult.union(rect)
        }
    }

    public var selectionAnchorRect: NSRect {
        guard let dataSource else {
            return .null
        }
        let temp = rangeOfVisibleLines
        let offset = dataSource.totalScrollbackOverflow()
        let visibleAbsRange = VT100GridAbsCoordRangeMake(0,
                                                         Int64(temp.location) + offset,
                                                         0,
                                                         Int64(temp.location) + Int64(temp.length) + offset)
        let visibleAbsLines = (visibleAbsRange.start.y)..<(visibleAbsRange.end.y)
        // Internal geometry: use raw allSubSelections. During an in-progress bidi
        // character drag the live range holds visual columns, which is exactly what a
        // pixel rect wants; logicalSubSelections would decompose it into logical runs.
        // (In practice this is only ever read against a committed selection, where the
        // two are identical, but the rule is: logical for external consumers, raw for
        // geometry.)
        for subselection in selection.allSubSelections {
            let absRange = subselection.absRange
            let selRange = absRange.coordRange.start.y..<(absRange.coordRange.end.y + 1)
            if visibleAbsLines.overlaps(selRange) {
                let visibleSelectedAbsRange = VT100GridAbsCoordRangeIntersection(absRange.coordRange,
                                                                                 visibleAbsRange,
                                                                                 dataSource.width())
                if visibleSelectedAbsRange.start.x >= 0 {
                    let hull = rect(for: visibleSelectedAbsRange)
                    if absRange.columnWindow.location >= 0 && absRange.columnWindow.length > 0 {
                        var columnRect = rect(
                            for: VT100GridAbsCoordRange(
                                start: VT100GridAbsCoord(
                                    x: absRange.columnWindow.location,
                                    y: offset),
                                end: VT100GridAbsCoord(
                                    x: absRange.columnWindow.location + absRange.columnWindow.length,
                                    y: offset)))
                        columnRect.origin.y = hull.origin.y
                        columnRect.size.height = hull.size.height
                        return columnRect.intersection(hull)
                    }
                    return hull
                }
            }
        }
        let cursorCoord = VT100GridCoord(x: dataSource.cursorX() - 1,
                                         y: dataSource.numberOfScrollbackLines() + dataSource.cursorY() - 1)
        let cursorAbsCoord = VT100GridAbsCoordFromCoord(cursorCoord, offset)
        if visibleAbsLines.contains(cursorAbsCoord.y) {
            return rect(for: cursorCoord)
        }
        return .null
     }
}

extension PTYTextView {
    @objc(swiftValidateMenuItem:)
    func swiftValidate(menuItem item: NSMenuItem) -> Bool {
        if item.action == #selector(downloadFiles(_:)) {
            return !ConductorRegistry.instance.isEmpty
        } else if item.action == #selector(saveArchive(_:)) {
            return true
        } else if item.action == #selector(toggleBufferInput(_:)) {
            item.state = (delegate?.textViewIsBufferingInput() ?? false) ? .on : .off
            return true
        } else if item.action == #selector(foldAll(_:)) {
            guard let dataSource else { return false }
            if dataSource.terminalSoftAlternateScreenMode() {
                return false
            }
            let cursorLine = dataSource.lineNumberOfCursor()
            // Disabled if cursor on first visible line
            if cursorLine <= 0 {
                return false
            }
            // Disabled if all lines above cursor are already folds. But only
            // check for smallish ranges to avoid this taking too long. If you
            // want to fold 100 folds go for it I guess.
            if cursorLine < 100 {
                let rangeAbove = VT100GridRange(location: 0, length: cursorLine)
                if dataSource.folds(in: rangeAbove).count == cursorLine {
                    return false
                }
            }
            return true
        }
        return false
    }

    @IBAction func downloadFiles(_ sender: Any) {
        let panel = iTermOpenPanel()
        panel.includeLocalhost = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        let provider = AITermController.provider
        panel.isSelectable = { remoteFile in
            return provider?.fileTypeIsSupported(extension: remoteFile.name.pathExtension.lowercased()) == true
        }
        panel.beginSSH(window: window) { response in
            guard response == .OK else {
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting(panel.items.map { $0.urlPromise.maybeValue }.compactMap { $0 as? URL })
        }
    }
}

@objc
extension PTYTextView {
    @IBAction
    @objc(saveArchive:)
    func saveArchive(_ sender: Any) {
        if let window = self.window {
            let savePanel = iTermModernSavePanel()
            savePanel.defaultFilename = ((delegate?.textViewVariablesScope().value(forVariableName: iTermVariableKeySessionName) as? String) ?? "iTerm2 Session") + ".itermarchive"
            savePanel.preferredSSHIdentity = .localhost
            savePanel.allowedContentTypes = [ UTType(filenameExtension: "itermarchive")! ]
            Task {
                let response = await savePanel.beginSheetModal(for: window)
                if response == .OK,
                   let item = savePanel.item {
                    delegate?.textViewSaveArchive(item)
                }
            }
        }
    }
}

@objc
extension PTYTextView {
    @IBAction
    @objc(toggleBufferInput:)
    func toggleBufferInput(_ sender: Any) {
        delegate?.textViewToggleBufferInput()
    }
}

// MARK: - Accessibility Deletion Detection

extension PTYTextView {
    /// Returns a located string for the current cursor line.
    /// Each character's grid coordinate is tracked for proper position-based comparison.
    @objc
    func accessibilityLocatedStringForCursorLine() -> iTermLocatedString {
        let result = iTermLocatedString()
        guard let dataSource else {
            return result
        }

        let cursorY = dataSource.cursorY()  // 1-based
        let lineIndex = dataSource.numberOfScrollbackLines() + cursorY - 1
        let lines = dataSource.lines(in: NSRange(location: Int(lineIndex), length: 1))

        guard let screenCharArray = lines?.first else {
            return result
        }

        let line = screenCharArray.line
        let length = Int(screenCharArray.length)
        let privateRange = unichar(ITERM2_PRIVATE_BEGIN)...unichar(ITERM2_PRIVATE_END)

        for x in 0..<length {
            var theChar = line[x]
            let coord = VT100GridCoordMake(Int32(x), cursorY - 1)

            if theChar.code == 0 || privateRange.contains(theChar.code) {
                // Nulls and private chars become spaces
                result.appendString(" ", at: coord)
            } else if theChar.image != 0 {
                // Skip images
                continue
            } else {
                let string = ScreenCharToStr(&theChar) ?? " "
                result.appendString(string, at: coord)
            }
        }

        return result
    }

    /// Detects text deletion by comparing old and new cursor line content.
    /// Returns the deleted text to announce, or nil if no deletion detected.
    @objc
    func accessibilityDetectDeletion(oldCursorX: Int32,
                                     newCursorX: Int32,
                                     oldLocatedString: iTermLocatedString,
                                     newLocatedString: iTermLocatedString) -> String? {
        // Grid coordinates use 0-based x values
        let oldGridX = oldCursorX - 1
        let newGridX = newCursorX - 1

        let oldCoords = oldLocatedString.gridCoords
        let oldString = oldLocatedString.string
        let newCoords = newLocatedString.gridCoords
        let newString = newLocatedString.string

        if newCursorX < oldCursorX {
            // Case A: Cursor moved left (backspace, word-delete, Ctrl+U)
            // Find characters in the old string with x in [newGridX, oldGridX)
            let oldRange = oldCoords.rangeOfIndices(xFrom: newGridX, to: oldGridX)
            if oldRange.location != NSNotFound && oldRange.length > 0 {
                let oldSub = (oldString as NSString).substring(with: oldRange)
                // Check if the text at those positions actually changed
                let newRange = newCoords.rangeOfIndices(xFrom: newGridX, to: oldGridX)
                let newSub = (newRange.location != NSNotFound && newRange.length > 0)
                    ? (newString as NSString).substring(with: newRange)
                    : ""
                if oldSub != newSub {
                    return oldSub
                }
            }
        } else if newCursorX == oldCursorX && oldString != newString {
            // Case B: Cursor stayed, line content changed (forward-delete, Ctrl+K)
            // Find characters at and after cursor position in both strings
            let oldStartIdx = oldCoords.indexOfFirstCoord(xGreaterOrEqual: newGridX)
            let newStartIdx = newCoords.indexOfFirstCoord(xGreaterOrEqual: newGridX)

            let oldAfter: String
            if oldStartIdx != NSNotFound {
                oldAfter = (oldString as NSString).substring(from: oldStartIdx)
            } else {
                oldAfter = ""
            }

            let newAfter: String
            if newStartIdx != NSNotFound {
                newAfter = (newString as NSString).substring(from: newStartIdx)
            } else {
                newAfter = ""
            }

            let whitespace = CharacterSet.whitespaces
            let oldTrimmed = oldAfter.trimmingCharacters(in: whitespace)
            let newTrimmed = newAfter.trimmingCharacters(in: whitespace)

            if !oldTrimmed.isEmpty && newTrimmed.isEmpty {
                // Kill to end (Ctrl+K): all text after cursor gone
                return oldTrimmed
            } else if !oldTrimmed.isEmpty && !oldAfter.hasPrefix(newAfter) {
                // Forward delete or other deletion: find what was removed
                // For single character forward delete, announce the first character
                if oldStartIdx != NSNotFound && oldStartIdx < oldString.count {
                    // Get the character(s) at the cursor position from old string
                    let cursorCoord = oldCoords.coord(at: oldStartIdx)
                    let charRange = oldCoords.rangeOfIndices(xFrom: cursorCoord.x, to: cursorCoord.x + 1)
                    if charRange.location != NSNotFound && charRange.length > 0 {
                        return (oldString as NSString).substring(with: charRange)
                    }
                }
            }
        }

        return nil
    }
}

// MARK: - Fold All

extension PTYTextView {
    @IBAction
    @objc(foldAll:)
    func foldAll(_ sender: Any) {
        foldAllAboveCursor()
    }

    @objc
    func foldAllAboveCursor() {
        guard let dataSource else { return }

        let cursorLine = dataSource.lineNumberOfCursor()
        guard cursorLine > 0 else { return }

        // Skip consecutive folds starting at line 0
        var startLine: Int32 = 0
        while startLine < cursorLine {
            let lineRange = VT100GridRange(location: startLine, length: 1)
            if (dataSource.folds(in: lineRange)?.count ?? 0) == 0 {
                break
            }
            startLine += 1
        }

        // If all lines are folds, nothing to do
        guard startLine < cursorLine else { return }

        // Range is from first non-fold line to cursorLine - 1
        let overflow = dataSource.totalScrollbackOverflow()
        let absStart = Int64(startLine) + overflow
        let absEnd = Int64(cursorLine) + overflow
        let range = absStart..<absEnd

        let placeholder = createFoldAllPlaceholder(range: range, dataSource: dataSource)
        let promptLength = self.promptLength(at: absStart)

        foldAllWithPlaceholder(range: range, promptLength: Int(promptLength), placeholder: placeholder)
    }

    private func createFoldAllPlaceholder(range: Range<Int64>, dataSource: PTYTextViewDataSource) -> ScreenCharArray {
        let width = dataSource.width()

        // Find first and last command marks with commands
        let (firstMark, lastMark) = findFirstAndLastCommandMarks(in: range, dataSource: dataSource)

        // Build placeholder text
        var parts: [String] = []

        // Localized compact date from first command's start date
        if let startDate = firstMark?.startDate {
            let formatter = DateFormatter()
            formatter.locale = Locale.current
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            parts.append(formatter.string(from: startDate))
            parts.append("—")  // em dash
        }

        // First command (truncated)
        if let cmd = firstMark?.firstLineOfCommand, !cmd.isEmpty {
            parts.append(String(cmd.prefix(20)))
        }

        // Line count
        let lineCount = Int(range.upperBound - range.lowerBound)
        parts.append(String(localized: "PTYTextView.PartsLineCount", defaultValue: "…\(lineCount) lines…", comment: "Line count marker in a compact description; %lld is the number of lines. Keep the surrounding ellipses."))

        // Last command if different
        if let lastCmd = lastMark?.firstLineOfCommand,
           !lastCmd.isEmpty,
           lastMark !== firstMark {
            parts.append(String(lastCmd.prefix(20)))
        }

        let text = parts.joined(separator: " ")
        return createStyledPlaceholderLine(text: text, width: width)
    }

    private func findFirstAndLastCommandMarks(
        in range: Range<Int64>,
        dataSource: PTYTextViewDataSource
    ) -> (first: VT100ScreenMarkReading?, last: VT100ScreenMarkReading?) {
        let absRange = NSRange(location: Int(range.lowerBound), length: Int(range.upperBound - range.lowerBound))
        return (dataSource.firstCommandMarkWithCommand(in: absRange),
                dataSource.lastCommandMarkWithCommand(in: absRange))
    }

    private func createStyledPlaceholderLine(text: String, width: Int32) -> ScreenCharArray {
        let result = MutableScreenCharArray()
        result.append(text, fg: screen_char_t(), bg: screen_char_t())

        // Pad to width
        let currentLength = Int32(result.lengthExcludingTrailingWhitespaceAndNulls)
        if currentLength < width {
            result.append(ScreenCharArray.emptyLine(ofLength: width - currentLength))
        }

        // Apply faint italic styling (same as existing fold style)
        var bg = screen_char_t()
        bg.backgroundColorMode = ColorModeAlternate.rawValue
        bg.backgroundColor = UInt32(ALTSEM_DEFAULT)
        result.setBackground(bg, in: NSRange(location: 0, length: Int(width)))

        var fg = screen_char_t()
        fg.foregroundColorMode = ColorModeAlternate.rawValue
        fg.foregroundColor = UInt32(ALTSEM_DEFAULT)
        fg.faint = 1
        fg.italic = 1
        result.setForeground(fg, in: NSRange(location: 0, length: Int(width)))

        var continuation = bg
        continuation.code = UInt16(EOL_HARD)
        result.continuation = continuation
        return result
    }

    private func foldAllWithPlaceholder(range: Range<Int64>, promptLength: Int, placeholder: ScreenCharArray) {
        guard let dataSource else { return }

        let absRange = VT100GridAbsCoordRange(
            start: VT100GridAbsCoord(x: 0, y: range.lowerBound),
            end: VT100GridAbsCoord(x: dataSource.width(), y: range.upperBound - 1)
        )

        let blockMarks = dataSource.blockMarkDictionary(onLine: range.lowerBound)
        dataSource.replace(absRange,
                           withLines: [placeholder.clone()],
                           promptLength: promptLength,
                           blockMarks: blockMarks)
        requestDelegateRedraw()
        didFoldOrUnfold()
    }
}

// MARK: - Extend URL Search Results Across Soft Boundaries


// MARK: - Inline Web Views (OSC 1337 WebView / WebViewMove / WebViewRemove)

struct InlineWebError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) {
        errorDescription = message
    }
}

private class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

// A clipping container overlaid on a rectangle of cells of the visible screen grid. It holds a WKWebView laid out at
// the block's full height and offset by the rows cropped off the top, so a partly scrolled-out block is cropped like
// text instead of re-laid out. State lives on the view itself so PTYTextView needs no extra storage.
@objc(iTermInlineWebView)
class InlineWebView: NSView, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, iTermMetalDisabling {
    func viewDisablesMetal() -> Bool { true }

    static let allowedHostsKey = "InlineWebViewAllowedHosts"
    static let consoleHandlerName = "iTermInlineWebConsole"
    var webViewID = ""
    var row = 0, col = 0, cols = 0, rows = 0, cropTop = 0, fullRows = 0
    let web: InlineWKWebView
    // Non-nil for views created over the control socket: they use the desktop URL policy with these file roots.
    let fileRoots: [String]?
    var loadError: String?
    // Kept so removal can still route the closed event after the view leaves its superview.
    fileprivate weak var owner: PTYTextView?
    private var waiters = [() -> Void]()
    private var observations = [NSKeyValueObservation]()
    private var eventScheduled = false
    private var pendingDialog: ((Bool, String?) -> Void)?
    private var dialogSerial = 0

    init(url: URL?, fileRoots: [String]? = nil) {
        self.fileRoots = fileRoots
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.addUserScript(WKUserScript(source: Self.consoleScript,
                                                                injectionTime: .atDocumentStart,
                                                                forMainFrameOnly: true))
        web = InlineWKWebView(frame: .zero, configuration: config)
        super.init(frame: .zero)
        config.userContentController.add(WeakScriptMessageHandler(self), name: Self.consoleHandlerName)
        wantsLayer = true
        layer?.masksToBounds = true
        web.navigationDelegate = self
        web.uiDelegate = self
        addSubview(web)
        let changed: (WKWebView) -> Void = { [weak self] _ in self?.stateDidChange() }
        observations = [web.observe(\.url) { w, _ in changed(w) },
                        web.observe(\.title) { w, _ in changed(w) },
                        web.observe(\.isLoading) { w, _ in changed(w) },
                        web.observe(\.canGoBack) { w, _ in changed(w) },
                        web.observe(\.canGoForward) { w, _ in changed(w) }]
        if let url {
            web.load(URLRequest(url: url))
        }
    }

    required init?(coder: NSCoder) {
        it_fatalError()
    }

    override var isFlipped: Bool { true }

    var textView: PTYTextView? { superview as? PTYTextView }

    var isActive: Bool {
        guard let responder = window?.firstResponder as? NSView else {
            return false
        }
        return responder.isDescendant(of: web)
    }

    // Until the page is clicked, the block behaves like text: scrolls go to the terminal (so OpenCode's history
    // scrolls under it) and the first click only activates the page.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        guard hit != nil else {
            return nil
        }
        return isActive ? hit : self
    }

    override func scrollWheel(with event: NSEvent) {
        textView?.scrollWheel(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        if !web.isHidden {
            window?.makeFirstResponder(web)
        }
    }

    // Shown over the cells instead of a page whose URL the allowlist refused.
    func showBlocked(_ host: String) {
        web.isHidden = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        let label = NSTextField(labelWithString: "Blocked by inline web allowlist: \(host)")
        label.frame = bounds
        label.autoresizingMask = [.width, .height]
        addSubview(label)
    }

    // MARK: URL policies

    static func isAllowed(_ url: URL?) -> Bool {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased() else {
            return false
        }
        let hosts = iTermUserDefaults.userDefaults().stringArray(forKey: allowedHostsKey) ?? ["localhost", "127.0.0.1", "example.com"]
        return hosts.map { $0.lowercased() }.contains(host)
    }

    static func decodeBase64URL(_ b64: String) -> URL? {
        guard let data = Data(base64Encoded: b64.padding(toLength: (b64.count + 3) / 4 * 4, withPad: "=", startingAt: 0)) else {
            return nil
        }
        return URL(string: String(decoding: data, as: UTF8.self))
    }

    // The address a controller asked for, with a scheme added like the desktop app's address bar does.
    static func desktopURL(_ input: String) -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty || value.lowercased() == "about:blank" {
            return URL(string: "about:blank")
        }
        if value.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*://", options: .regularExpression) != nil {
            return URL(string: value)
        }
        let local = value.range(of: #"^(?:(?:[a-z\d-]+\.)*localhost|127(?:\.\d{1,3}){3}|\[::1\])(?::\d+)?(?:[/?#]|$)"#,
                                options: [.regularExpression, .caseInsensitive]) != nil
        return URL(string: (local ? "http://" : "https://") + value)
    }

    // Desktop policy: any http(s) page without credentials, about:blank, and local files inside a root.
    static func desktopRefusal(_ url: URL, fileRoots: [String]) -> String? {
        let scheme = url.scheme?.lowercased() ?? ""
        if url.absoluteString.lowercased() == "about:blank" || fileRoot(of: url, in: fileRoots) != nil {
            return nil
        }
        if ["http", "https"].contains(scheme) && !(url.host ?? "").isEmpty {
            return url.user == nil && url.password == nil ? nil : "URLs with a user name or password are not supported. Remove them from the URL."
        }
        return fileRoots.isEmpty
            ? "Only HTTP, HTTPS, and about:blank URLs are supported."
            : "Only HTTP, HTTPS, about:blank, and file URLs inside the workspace are supported."
    }

    static func fileRoot(of url: URL, in roots: [String]) -> String? {
        guard url.isFileURL, (url.host ?? "").isEmpty else {
            return nil
        }
        let path = url.standardized.path
        return roots.first { root in
            var prefix = root
            while prefix.hasSuffix("/") {
                prefix.removeLast()
            }
            return path == prefix || path.hasPrefix(prefix + "/")
        }
    }

    func refusal(_ url: URL) -> String? {
        guard let fileRoots else {
            return Self.isAllowed(url) ? nil : "Blocked by inline web allowlist: \(url.host ?? url.absoluteString)"
        }
        return Self.desktopRefusal(url, fileRoots: fileRoots)
    }

    func open(_ url: URL) throws {
        if let reason = refusal(url) {
            throw InlineWebError(reason)
        }
        loadError = nil
        if let fileRoots, let root = Self.fileRoot(of: url, in: fileRoots) {
            web.loadFileURL(url, allowingReadAccessTo: URL(fileURLWithPath: root))
        } else {
            web.load(URLRequest(url: url))
        }
    }

    // Top-level navigations (including redirects and link clicks) must stay within the view's policy.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let isSubframe = navigationAction.targetFrame.map { !$0.isMainFrame } ?? false
        let allowed = navigationAction.request.url.map { refusal($0) == nil } ?? false
        decisionHandler(isSubframe || allowed ? .allow : .cancel)
    }

    // target=_blank links open in place.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
            try? open(url)
        }
        return nil
    }

    // MARK: Navigation state

    var info: [String: Any] {
        var info: [String: Any] = ["view": webViewID,
                                   "url": web.url?.absoluteString ?? "",
                                   "title": web.title ?? "",
                                   "loading": web.isLoading,
                                   "canGoBack": web.canGoBack,
                                   "canGoForward": web.canGoForward]
        if let loadError {
            info["loadError"] = loadError
        }
        return info
    }

    func emit(_ event: [String: Any]) {
        if let owner {
            InlineWebControl.shared.send(event, to: owner)
        }
    }

    private func stateDidChange() {
        if !web.isLoading {
            flushWaiters()
        }
        guard !eventScheduled else {
            return
        }
        eventScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }
            eventScheduled = false
            emit(info.merging(["event": "navigation"]) { a, _ in a })
        }
    }

    // Runs `done` once the current navigation settles. Same-document navigations never start loading, so they
    // settle on the first check; a stuck load gives up after 30s.
    func afterNavigation(_ done: @escaping () -> Void) {
        waiters.append(done)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            if self?.web.isLoading == false {
                self?.flushWaiters()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.flushWaiters()
        }
    }

    private func flushWaiters() {
        let waiters = self.waiters
        self.waiters = []
        waiters.forEach { $0() }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        loadError = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    private func loadFailed(_ error: Error) {
        if (error as NSError).code != NSURLErrorCancelled {
            loadError = error.localizedDescription
        }
        flushWaiters()
        stateDidChange()
    }

    // Called just before the view leaves its text view, for any reason.
    fileprivate func willClose() {
        _ = answerDialog(accept: false, text: nil)
        flushWaiters()
        emit(["event": "closed", "view": webViewID])
    }

    // MARK: Console

    private static let consoleScript = """
    (() => {
      const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(consoleHandlerName);
      if (!handler) return;
      const str = (a) => { try { return typeof a === "string" ? a : a instanceof Error ? (a.stack || String(a)) : (JSON.stringify(a) ?? String(a)); } catch { return String(a); } };
      const post = (level, args, extra) => { try { handler.postMessage(Object.assign({ level, text: args.map(str).join(" ").slice(0, 10000) }, extra || {})); } catch {} };
      for (const level of ["log", "info", "warn", "error", "debug"]) {
        const original = console[level];
        console[level] = function (...args) { post(level, args); return original.apply(this, args); };
      }
      addEventListener("error", (e) => post("error", [e.message], { url: e.filename, line: e.lineno, column: e.colno }));
      addEventListener("unhandledrejection", (e) => post("error", ["Unhandled rejection:", e.reason]));
    })();
    """

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let owner, InlineWebControl.shared.isControlled(owner),
              let body = message.body as? [String: Any],
              let level = body["level"] as? String, let text = body["text"] as? String else {
            return
        }
        var event: [String: Any] = ["event": "console", "view": webViewID, "level": String(level.prefix(16)), "text": String(text.prefix(10_000))]
        if let url = body["url"] as? String {
            event["url"] = String(url.prefix(2048))
        }
        if let line = body["line"] as? Int {
            event["line"] = line
        }
        if let column = body["column"] as? Int {
            event["column"] = column
        }
        emit(event)
    }

    // MARK: Dialogs

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        ask(["type": "alert", "message": message]) { _, _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        ask(["type": "confirm", "message": message]) { accept, _ in completionHandler(accept) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        ask(["type": "prompt", "message": prompt, "defaultText": defaultText ?? ""]) { accept, text in
            completionHandler(accept ? (text ?? defaultText ?? "") : nil)
        }
    }

    // Held for the controller to answer; without one nobody can, so it is dismissed right away.
    private func ask(_ dialog: [String: Any], _ answer: @escaping (Bool, String?) -> Void) {
        guard pendingDialog == nil, let owner, InlineWebControl.shared.isControlled(owner) else {
            answer(false, nil)
            return
        }
        pendingDialog = answer
        dialogSerial += 1
        let serial = dialogSerial
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            if self?.dialogSerial == serial {
                _ = self?.answerDialog(accept: false, text: nil)
            }
        }
        emit(dialog.merging(["event": "dialog", "view": webViewID]) { a, _ in a })
    }

    func answerDialog(accept: Bool, text: String?) -> Bool {
        guard let pendingDialog else {
            return false
        }
        self.pendingDialog = nil
        dialogSerial += 1
        pendingDialog(accept, text)
        return true
    }

    // MARK: Snapshot and trusted input

    func screenshot(rect: NSRect?, _ done: @escaping (Result<Any, Error>) -> Void) {
        let config = WKSnapshotConfiguration()
        if let rect {
            config.rect = rect
        }
        web.takeSnapshot(with: config) { image, error in
            guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
                done(.failure(error ?? InlineWebError("Snapshot failed.")))
                return
            }
            done(.success(["png": png.base64EncodedString(), "width": cg.width, "height": cg.height]))
        }
    }

    // CSS px relative to the page viewport, in window coordinates.
    private func windowPoint(_ x: Double, _ y: Double) -> NSPoint {
        return web.convert(NSPoint(x: x, y: web.isFlipped ? y : web.bounds.height - y), to: nil)
    }

    // Synthetic events must never move keyboard focus away from the terminal.
    private func inWindow(_ body: (NSWindow) throws -> Void) throws {
        guard let window = web.window else {
            throw InlineWebError("The web view is not in a window.")
        }
        let before = window.firstResponder
        defer {
            if window.firstResponder !== before {
                window.makeFirstResponder(before)
            }
        }
        try body(window)
    }

    func mouse(_ type: String, x: Double, y: Double, button: String, clickCount: Int) throws {
        try inWindow { window in
            let (down, up): (NSEvent.EventType, NSEvent.EventType) = switch button {
            case "right": (.rightMouseDown, .rightMouseUp)
            case "middle": (.otherMouseDown, .otherMouseUp)
            default: (.leftMouseDown, .leftMouseUp)
            }
            let location = windowPoint(x, y)
            func send(_ type: NSEvent.EventType) {
                guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                     timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                     clickCount: type == .mouseMoved ? 0 : clickCount,
                                                     pressure: type == down ? 1 : 0) else {
                    return
                }
                switch type {
                case .mouseMoved: web.mouseMoved(with: event)
                case .leftMouseDown: web.mouseDown(with: event)
                case .leftMouseUp: web.mouseUp(with: event)
                case .rightMouseDown: web.rightMouseDown(with: event)
                case .rightMouseUp: web.rightMouseUp(with: event)
                case .otherMouseDown: web.otherMouseDown(with: event)
                case .otherMouseUp: web.otherMouseUp(with: event)
                default: break
                }
            }
            switch type {
            case "move": send(.mouseMoved)
            case "down": send(down)
            case "up": send(up)
            case "click":
                send(.mouseMoved)
                send(down)
                send(up)
            default: throw InlineWebError("Unknown mouse type \(type).")
            }
        }
    }

    func scroll(x: Double, y: Double, dx: Double, dy: Double) throws {
        try inWindow { window in
            let clamp = { (v: Double) in Int32(max(-1_000_000, min(1_000_000, -v))) }
            let point = window.convertPoint(toScreen: windowPoint(x, y))
            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                   wheel1: clamp(dy), wheel2: clamp(dx), wheel3: 0) else {
                throw InlineWebError("Could not create a scroll event.")
            }
            // CGEvent locations are global, with the origin at the top left of the main display.
            cg.location = CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.height ?? 0) - point.y)
            guard let event = NSEvent(cgEvent: cg) else {
                throw InlineWebError("Could not create a scroll event.")
            }
            web.scrollWheel(with: event)
        }
    }

    private static func functionKey(_ key: Int) -> String {
        return String(Character(UnicodeScalar(UInt32(key))!))
    }

    private static let namedKeys: [String: (code: UInt16, chars: String, function: Bool)] = [
        "Enter": (36, "\r", false), "Tab": (48, "\t", false), "Escape": (53, "\u{1b}", false),
        "Backspace": (51, "\u{7f}", false), "Space": (49, " ", false),
        "Delete": (117, functionKey(NSDeleteFunctionKey), true),
        "ArrowUp": (126, functionKey(NSUpArrowFunctionKey), true),
        "ArrowDown": (125, functionKey(NSDownArrowFunctionKey), true),
        "ArrowLeft": (123, functionKey(NSLeftArrowFunctionKey), true),
        "ArrowRight": (124, functionKey(NSRightArrowFunctionKey), true),
        "Home": (115, functionKey(NSHomeFunctionKey), true), "End": (119, functionKey(NSEndFunctionKey), true),
        "PageUp": (116, functionKey(NSPageUpFunctionKey), true), "PageDown": (121, functionKey(NSPageDownFunctionKey), true),
    ]

    func key(text: String?, key: String?, modifiers: [String]) throws {
        var flags: NSEvent.ModifierFlags = []
        for modifier in modifiers {
            switch modifier {
            case "shift": flags.insert(.shift)
            case "meta": flags.insert(.command)
            case "alt": flags.insert(.option)
            case "ctrl": flags.insert(.control)
            default: throw InlineWebError("Unknown modifier \(modifier).")
            }
        }
        var strokes = [(code: UInt16, chars: String, flags: NSEvent.ModifierFlags)]()
        if let key {
            if let named = Self.namedKeys[key] {
                strokes.append((named.code, named.chars, named.function ? flags.union([.function, .numericPad]) : flags))
            } else if key.count == 1 {
                // shortcut: shift only uppercases letters, use a keyboard layout map if symbols are needed.
                strokes.append((0, flags.contains(.shift) ? key.uppercased() : key, flags))
            } else {
                throw InlineWebError("Unknown key \(key).")
            }
        }
        for character in (text ?? "").prefix(10_000) {
            strokes.append((0, String(character), flags))
        }
        guard !strokes.isEmpty else {
            throw InlineWebError("key needs text or key.")
        }
        try inWindow { window in
            for stroke in strokes {
                func make(_ type: NSEvent.EventType) -> NSEvent? {
                    return NSEvent.keyEvent(with: type, location: .zero, modifierFlags: stroke.flags,
                                            timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil,
                                            characters: stroke.chars, charactersIgnoringModifiers: stroke.chars,
                                            isARepeat: false, keyCode: stroke.code)
                }
                guard let down = make(.keyDown), let up = make(.keyUp) else {
                    continue
                }
                if !(stroke.flags.contains(.command) && web.performKeyEquivalent(with: down)) {
                    web.synthesizedKeyDown(down)
                }
                web.keyUp(with: up)
            }
        }
    }
}

class InlineWKWebView: WKWebView {
    private func deactivate() {
        window?.makeFirstResponder((superview as? InlineWebView)?.textView)
    }

    // Esc (with or without Cmd) hands keyboard focus back to the terminal.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            deactivate()
            return
        }
        super.keyDown(with: event)
    }

    // A controller's Escape goes to the page.
    func synthesizedKeyDown(_ event: NSEvent) {
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.keyCode == 53 && (window?.firstResponder as? NSView)?.isDescendant(of: self) == true {
            deactivate()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

extension PTYTextView {
    fileprivate var inlineWebViews: [InlineWebView] {
        return subviews.compactMap { $0 as? InlineWebView }
    }

    @objc(handleInlineWebViewCommand:value:)
    func handleInlineWebViewCommand(_ command: String, value: String) {
        var args = [String: String]()
        for part in value.components(separatedBy: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 {
                args[kv[0]] = kv[1]
            }
        }
        guard let id = args["id"], !id.isEmpty else {
            return
        }
        switch command {
        case "WebView", "WebViewMove":
            if let view = inlineWebViews.first(where: { $0.webViewID == id }),
               command == "WebViewMove" || view.fileRoots != nil {
                // Moves, and placements of views a controller created over the control socket, keep the page.
                place(view, args)
            } else if command == "WebView" || args["url"] != nil {
                // A move with a url recreates a view this process doesn't know, e.g. after an iTerm2 restart.
                let url = args["url"].flatMap(InlineWebView.decodeBase64URL)
                let allowed = InlineWebView.isAllowed(url)
                removeInlineWebViews(id: id)
                let view = InlineWebView(url: allowed ? url : nil)
                if !allowed {
                    DLog("Blocking inline web view \(id)")
                    view.showBlocked(url?.host ?? "invalid URL")
                }
                place(view, args)
                addInlineWebView(view, id: id)
                return
            } else {
                return
            }
        case "WebViewRemove":
            removeInlineWebViews(id: id)
            return
        default:
            return
        }
        updateInlineWebViewFrames()
    }

    fileprivate func addInlineWebView(_ view: InlineWebView, id: String) {
        view.webViewID = id
        view.owner = self
        addSubview(view)
        inlineWebViewsDidChange()
    }

    private func inlineWebViewsDidChange() {
        updateInlineWebViewFrames()
        NotificationCenter.default.post(name: NSNotification.Name.iTermPortholesDidChange, object: nil)
        updateAlphaValue()
        delegate?.textViewDidAddOrRemovePorthole()
    }

    private func place(_ view: InlineWebView, _ args: [String: String]) {
        view.row = args["row"].flatMap { Int($0) } ?? view.row
        view.col = args["col"].flatMap { Int($0) } ?? view.col
        view.cols = args["w"].flatMap { Int($0) } ?? view.cols
        view.rows = args["h"].flatMap { Int($0) } ?? view.rows
        // Clamped so the CGFloat math below stays sane for any input.
        view.cropTop = min(max(args["oy"].flatMap { Int($0) } ?? 0, 0), 10_000)
        view.fullRows = min(max(args["fh"].flatMap { Int($0) } ?? 0, 0), 10_000)
    }

    @objc func removeAllInlineWebViews() {
        removeInlineWebViews(id: "*")
    }

    fileprivate func removeInlineWebViews(id: String) {
        let doomed = inlineWebViews.filter { id == "*" || $0.webViewID == id }
        guard !doomed.isEmpty else {
            return
        }
        if let responder = window?.firstResponder as? NSView, doomed.contains(where: { responder.isDescendant(of: $0) }) {
            window?.makeFirstResponder(self)
        }
        doomed.forEach {
            $0.willClose()
            $0.removeFromSuperview()
        }
        inlineWebViewsDidChange()
    }

    // Cells are relative to the visible screen grid, which starts below the scrollback.
    @objc func updateInlineWebViewFrames() {
        guard let dataSource else {
            return
        }
        let top = CGFloat(dataSource.numberOfScrollbackLines()) * lineHeight + CGFloat(iTermPreferences.topBottomMargins())
        let left = CGFloat(iTermPreferences.sideMargins())
        let width = Int(dataSource.width()), height = Int(dataSource.height())
        for view in inlineWebViews {
            view.isHidden = view.cols <= 0 || view.rows <= 0 || view.row < 0 || view.col < 0 || view.row >= height || view.col >= width
            // Skipping hidden views keeps the subtractions below in range for any parsed Int.
            if view.isHidden {
                // A controller's view that was never placed still needs a viewport to lay out and snapshot.
                if view.web.frame.isEmpty {
                    view.web.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
                }
                continue
            }
            view.frame = NSRect(x: left + CGFloat(view.col) * charWidth,
                                y: top + CGFloat(view.row) * lineHeight,
                                width: CGFloat(max(0, min(view.cols, width - view.col))) * charWidth,
                                height: CGFloat(max(0, min(view.rows, height - view.row))) * lineHeight)
            view.web.frame = NSRect(x: 0,
                                    y: -CGFloat(view.cropTop) * lineHeight,
                                    width: view.frame.width,
                                    height: CGFloat(max(view.fullRows, view.cropTop + view.rows)) * lineHeight)
        }
    }
}

// MARK: - Inline web control socket

// A per-process Unix socket through which a program in a session (e.g. an OpenCode TUI plugin) drives that session's
// inline web views. Socket IO runs on background threads; everything else on the main thread. See PROTOCOL.md.
@objc(iTermInlineWebControl)
class InlineWebControl: NSObject {
    static let shared = InlineWebControl()
    private var path: String?
    private let tokens = NSMapTable<PTYSession, NSString>.weakToStrongObjects()
    private var connections = [Connection]()

    final class Connection {
        let fd: Int32
        weak var session: PTYSession?
        var bound = false
        private let writeQueue = DispatchQueue(label: "com.iterm2.inline-web-control.write")

        init(fd: Int32) {
            self.fd = fd
        }

        func readLoop() {
            var buffer = [UInt8]()
            var chunk = [UInt8](repeating: 0, count: 65536)
            while buffer.count < 16 << 20 {
                let n = read(fd, &chunk, chunk.count)
                if n < 0 && errno == EINTR {
                    continue
                }
                if n <= 0 {
                    break
                }
                buffer.append(contentsOf: chunk[0..<n])
                while let newline = buffer.firstIndex(of: 10) {
                    let line = Data(buffer[..<newline])
                    buffer.removeFirst(newline + 1)
                    DispatchQueue.main.async {
                        InlineWebControl.shared.handle(line, from: self)
                    }
                }
            }
            DispatchQueue.main.async {
                InlineWebControl.shared.connections.removeAll { $0 === self }
            }
            writeQueue.async { [fd] in
                Darwin.close(fd)
            }
        }

        func send(_ object: [String: Any]) {
            guard var data = try? JSONSerialization.data(withJSONObject: object) else {
                return
            }
            data.append(10)
            writeQueue.async { [fd] in
                data.withUnsafeBytes { buf in
                    var offset = 0
                    while offset < buf.count {
                        let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
                        if n < 0 && errno == EINTR {
                            continue
                        }
                        if n <= 0 {
                            return
                        }
                        offset += n
                    }
                }
            }
        }

        func close() {
            writeQueue.async { [fd] in
                shutdown(fd, SHUT_RDWR)
            }
        }
    }

    @objc(environmentForSession:)
    static func environment(for session: PTYSession) -> [String: String] {
        return shared.environment(for: session)
    }

    private func environment(for session: PTYSession) -> [String: String] {
        guard let path = start() else {
            return [:]
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard let token = tokens.object(forKey: session) as String? ??
                (SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess
                    ? bytes.map { String(format: "%02x", $0) }.joined()
                    : nil) else {
            return [:]
        }
        tokens.setObject(token as NSString, forKey: session)
        return ["ITERM_INLINEWEB_SOCKET": path, "ITERM_INLINEWEB_TOKEN": token]
    }

    private func start() -> String? {
        if let path {
            return path
        }
        // Own subdirectory, so tightening it never changes the folder stock iTerm2 shares.
        let dir = NSHomeDirectory() + "/Library/Application Support/iTerm2/inlineweb"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        chmod(dir, 0o700)
        let path = dir + "/inlineweb-\(getpid()).sock"
        // Sockets of processes that died without quitting (e.g. SIGTERM).
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
            if name.hasPrefix("inlineweb-"), name.hasSuffix(".sock"),
               let pid = pid_t(name.dropFirst(10).dropLast(5)), kill(pid, 0) != 0, errno == ESRCH {
                unlink(dir + "/" + name)
            }
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            DLog("Inline web control socket path too long: \(path)")
            return nil
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return nil
        }
        unlink(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        } == 0
        guard bound, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            DLog("Inline web control socket failed: \(errno)")
            Darwin.close(fd)
            unlink(path)
            return nil
        }
        self.path = path
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            unlink(path)
        }
        Thread.detachNewThread {
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 {
                    if errno == EINTR || errno == ECONNABORTED {
                        continue
                    }
                    return
                }
                var uid = uid_t(0), gid = gid_t(0)
                guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
                    Darwin.close(client)
                    continue
                }
                var on: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                let connection = Connection(fd: client)
                Thread.detachNewThread {
                    connection.readLoop()
                }
            }
        }
        return path
    }

    func isControlled(_ textView: PTYTextView) -> Bool {
        return connections.contains { $0.session?.textview === textView }
    }

    func send(_ event: [String: Any], to textView: PTYTextView) {
        for connection in connections where connection.session?.textview === textView {
            connection.send(event)
        }
    }

    private func handle(_ line: Data, from connection: Connection) {
        guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            connection.send(["ok": false, "error": "Invalid JSON."])
            return
        }
        if !connection.bound {
            guard let hello = message["hello"] as? [String: Any],
                  let token = hello["token"] as? String,
                  let session = tokens.keyEnumerator().allObjects.compactMap({ $0 as? PTYSession }).first(where: {
                      (tokens.object(forKey: $0) as String?) == token
                  }) else {
                connection.send(["ok": false, "error": "Bad token."])
                connection.close()
                return
            }
            connection.bound = true
            connection.session = session
            connections.append(connection)
            connection.send(["ok": true, "hello": ["version": 1]])
            return
        }
        let id = message["id"] ?? NSNull()
        let reply: (Result<Any, Error>) -> Void = { result in
            var response: [String: Any]
            switch result {
            case .success(let value):
                response = ["id": id, "ok": true, "value": value]
            case .failure(let error):
                let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
                response = ["id": id, "ok": false, "error": message]
            }
            if !JSONSerialization.isValidJSONObject(response) {
                response = ["id": id, "ok": false, "error": "The result is not JSON-serializable."]
            }
            connection.send(response)
        }
        do {
            guard let op = message["op"] as? String else {
                throw InlineWebError("Missing op.")
            }
            guard let textView = connection.session?.textview else {
                throw InlineWebError("The session is gone.")
            }
            try perform(op, message["args"] as? [String: Any] ?? [:], textView, reply)
        } catch {
            reply(.failure(error))
        }
    }

    private func perform(_ op: String, _ args: [String: Any], _ textView: PTYTextView, _ reply: @escaping (Result<Any, Error>) -> Void) throws {
        if op == "list" {
            reply(.success(textView.inlineWebViews.filter { !$0.web.isHidden }.map { $0.info }))
            return
        }
        guard let id = args["view"] as? String, !id.isEmpty else {
            throw InlineWebError("Missing view.")
        }
        let existing = textView.inlineWebViews.first { $0.webViewID == id }
        // Placeholders (showBlocked hides the web view) are not addressable.
        if existing?.web.isHidden == true {
            throw InlineWebError("Blocked by the inline web allowlist.")
        }
        func url() throws -> URL {
            guard let url = InlineWebView.desktopURL(args["url"] as? String ?? "") else {
                throw InlineWebError("Invalid URL.")
            }
            return url
        }
        func number(_ key: String) throws -> Double {
            guard let value = args[key] as? Double else {
                throw InlineWebError("Missing number \(key).")
            }
            return value
        }
        if op == "create" {
            let url = try url()
            let view = existing ?? InlineWebView(url: nil, fileRoots: args["fileRoots"] as? [String] ?? [])
            try view.open(url)
            if existing == nil {
                textView.addInlineWebView(view, id: id)
            }
            view.afterNavigation { reply(.success(view.info)) }
            return
        }
        guard let view = existing else {
            throw InlineWebError("No web view \(id) in this session.")
        }
        let afterNavigation = { view.afterNavigation { reply(.success(view.info)) } }
        switch op {
        case "navigate":
            try view.open(try url())
            afterNavigation()
        case "back":
            guard view.web.goBack() != nil else {
                throw InlineWebError("Cannot go back.")
            }
            afterNavigation()
        case "forward":
            guard view.web.goForward() != nil else {
                throw InlineWebError("Cannot go forward.")
            }
            afterNavigation()
        case "reload":
            view.web.reload()
            afterNavigation()
        case "stop":
            view.web.stopLoading()
            reply(.success(view.info))
        case "eval":
            guard let script = args["script"] as? String else {
                throw InlineWebError("Missing script.")
            }
            view.web.callAsyncJavaScript(script, arguments: args["args"] as? [String: Any] ?? [:], in: nil, in: .page) { result in
                reply(result.flatMap { value in
                    let value = Self.jsonValue(value)
                    guard let data = try? JSONSerialization.data(withJSONObject: [value]) else {
                        return .failure(InlineWebError("The result is not JSON-serializable."))
                    }
                    guard data.count <= 512 * 1024 else {
                        return .failure(InlineWebError("The result is \(data.count) bytes; the limit is 524288."))
                    }
                    return .success(value)
                })
            }
        case "screenshot":
            var rect: NSRect?
            if let r = args["rect"] as? [String: Any] {
                rect = NSRect(x: r["x"] as? Double ?? 0, y: r["y"] as? Double ?? 0, width: r["w"] as? Double ?? 0, height: r["h"] as? Double ?? 0)
            }
            view.screenshot(rect: rect, reply)
        case "mouse":
            try view.mouse(args["type"] as? String ?? "", x: try number("x"), y: try number("y"),
                           button: args["button"] as? String ?? "left", clickCount: args["clickCount"] as? Int ?? 1)
            reply(.success(NSNull()))
        case "scroll":
            try view.scroll(x: try number("x"), y: try number("y"), dx: args["dx"] as? Double ?? 0, dy: args["dy"] as? Double ?? 0)
            reply(.success(NSNull()))
        case "key":
            try view.key(text: args["text"] as? String, key: args["key"] as? String, modifiers: args["modifiers"] as? [String] ?? [])
            reply(.success(NSNull()))
        case "dialog":
            guard view.answerDialog(accept: args["accept"] as? Bool ?? false, text: args["text"] as? String) else {
                throw InlineWebError("No dialog is open.")
            }
            reply(.success(NSNull()))
        case "remove":
            textView.removeInlineWebViews(id: id)
            reply(.success(NSNull()))
        default:
            throw InlineWebError("Unknown op \(op).")
        }
    }

    // WebKit returns dates as NSDate, which JSON can't hold.
    private static func jsonValue(_ value: Any) -> Any {
        switch value {
        case let date as Date: return ISO8601DateFormatter().string(from: date)
        case let array as [Any]: return array.map(jsonValue)
        case let dict as [String: Any]: return dict.mapValues(jsonValue)
        default: return value
        }
    }
}
