/// ChangeSizeCalculation.swift

import Foundation

class ChangeSizeCalculation: WindowCalculation, ChangeWindowDimensionCalculation {

    // Calculation instances are shared for the lifetime of the app. Read
    // editable preferences at execution time so changes take effect at once.
    var screenEdgeGapSize: CGFloat {
        let gap = Defaults.gapSize.value
        return gap <= 0 ? 5.0 : CGFloat(gap)
    }
    var sizeOffsetAbs: CGFloat {
        let offset = Defaults.sizeOffset.value
        return offset <= 0 ? 30.0 : CGFloat(offset)
    }
    var curtainChangeSize: Bool { Defaults.curtainChangeSize.enabled != false }
    var smallerShrinksMaximizedHeight: Bool { Defaults.smallerShrinksMaximizedHeight.enabled }

    var widthOffsetAbs: CGFloat {
        CGFloat(Defaults.widthStepSize.value)
    }

    override func calculateRect(_ params: RectCalculationParameters) -> RectResult {

        let sizeOffset: CGFloat
        switch params.action {
            case .larger, .largerHeight:
                sizeOffset = sizeOffsetAbs
            case .smaller, .smallerHeight:
                sizeOffset = -sizeOffsetAbs
            case .largerWidth:
                sizeOffset = widthOffsetAbs
            case .smallerWidth:
                sizeOffset = -widthOffsetAbs
            default:
                sizeOffset = 0
        }

        let visibleFrameOfScreen = params.visibleFrameOfScreen
        let window = params.window

        // Calculate Width

        var resizedWindowRect = window.rect

        if [.larger, .smaller, .largerWidth, .smallerWidth].contains(params.action) {
            resizedWindowRect.size.width = resizedWindowRect.width + sizeOffset
            resizedWindowRect.origin.x = resizedWindowRect.minX - floor(sizeOffset / 2.0)

            if curtainChangeSize {
                resizedWindowRect = againstLeftAndRightScreenEdges(
                    originalWindowRect: window.rect,
                    resizedWindowRect: resizedWindowRect,
                    visibleFrameOfScreen: visibleFrameOfScreen
                )
            }

            if resizedWindowRect.width >= visibleFrameOfScreen.width {
                resizedWindowRect.size.width = visibleFrameOfScreen.width
            }
        }

        // Calculate Height

        if [.larger, .smaller, .largerHeight, .smallerHeight].contains(params.action) {
            resizedWindowRect.size.height = resizedWindowRect.height + sizeOffset
            resizedWindowRect.origin.y = resizedWindowRect.minY - floor(sizeOffset / 2.0)

            // The height-only Smaller command skips the top/bottom edge curtain so it can
            // shrink even a full-height window. smallerShrinksMaximizedHeight extends that
            // exemption to the combined Smaller command, which otherwise keeps the height
            // of a window pinned to the top and bottom screen edges.
            let heightCurtainActions: [WindowAction] = smallerShrinksMaximizedHeight
                ? [.smaller, .smallerHeight]
                : [.smallerHeight]

            if curtainChangeSize, !heightCurtainActions.contains(params.action) {
                resizedWindowRect = againstTopAndBottomScreenEdges(
                    originalWindowRect: window.rect,
                    resizedWindowRect: resizedWindowRect,
                    visibleFrameOfScreen: visibleFrameOfScreen
                )
            }

            if resizedWindowRect.height >= visibleFrameOfScreen.height {
                resizedWindowRect.size.height = visibleFrameOfScreen.height
                resizedWindowRect.origin.y = params.window.rect.minY
            }
        }


        if againstAllScreenEdges(windowRect: window.rect, visibleFrameOfScreen: visibleFrameOfScreen) && (sizeOffset < 0) {
            resizedWindowRect.size.width = params.window.rect.width + sizeOffset
            resizedWindowRect.origin.x = params.window.rect.origin.x - floor(sizeOffset / 2.0)
            resizedWindowRect.size.height = params.window.rect.height + sizeOffset
            resizedWindowRect.origin.y = params.window.rect.origin.y - floor(sizeOffset / 2.0)
        }
        
        if [.smaller, .smallerWidth, .smallerHeight].contains(params.action), resizedWindowRectIsTooSmall(windowRect: resizedWindowRect, visibleFrameOfScreen: visibleFrameOfScreen) {
            resizedWindowRect = window.rect
        }

        return RectResult(resizedWindowRect)
    }

    private func againstScreenEdge(_ gap: CGFloat) -> Bool {
        return abs(gap) <= screenEdgeGapSize
    }

    private func againstLeftScreenEdge(_ windowRect: CGRect, _ visibleFrameOfScreen: CGRect) -> Bool {
        return againstScreenEdge(windowRect.minX - visibleFrameOfScreen.minX)
    }

    private func againstRightScreenEdge(_ windowRect: CGRect, _ visibleFrameOfScreen: CGRect) -> Bool {
        return againstScreenEdge(windowRect.maxX - visibleFrameOfScreen.maxX)
    }

    private func againstTopScreenEdge(_ windowRect: CGRect, _ visibleFrameOfScreen: CGRect) -> Bool {
        return againstScreenEdge(windowRect.maxY - visibleFrameOfScreen.maxY)
    }

    private func againstBottomScreenEdge(_ windowRect: CGRect, _ visibleFrameOfScreen: CGRect) -> Bool {
        return againstScreenEdge(windowRect.minY - visibleFrameOfScreen.minY)
    }

    private func againstAllScreenEdges(windowRect: CGRect, visibleFrameOfScreen: CGRect) -> Bool {
        return (againstLeftScreenEdge(windowRect, visibleFrameOfScreen)
            && againstRightScreenEdge(windowRect, visibleFrameOfScreen)
            && againstTopScreenEdge(windowRect, visibleFrameOfScreen)
            && againstBottomScreenEdge(windowRect, visibleFrameOfScreen))
    }

    private func againstLeftAndRightScreenEdges(originalWindowRect: CGRect, resizedWindowRect: CGRect, visibleFrameOfScreen: CGRect) -> CGRect {
        var adjustedWindowRect = resizedWindowRect
        if againstRightScreenEdge(originalWindowRect, visibleFrameOfScreen) {
            adjustedWindowRect.origin.x = visibleFrameOfScreen.maxX - adjustedWindowRect.width - CGFloat(Defaults.gapSize.value)
            if againstLeftScreenEdge(originalWindowRect, visibleFrameOfScreen) {
                adjustedWindowRect.size.width = visibleFrameOfScreen.width - (CGFloat(Defaults.gapSize.value) * 2)
            }
        }
        if againstLeftScreenEdge(originalWindowRect, visibleFrameOfScreen) {
            adjustedWindowRect.origin.x = visibleFrameOfScreen.minX + CGFloat(Defaults.gapSize.value)
        }
        return adjustedWindowRect
    }

    private func againstTopAndBottomScreenEdges(originalWindowRect: CGRect, resizedWindowRect: CGRect, visibleFrameOfScreen: CGRect) -> CGRect{
        var adjustedWindowRect = resizedWindowRect
        if againstTopScreenEdge(originalWindowRect, visibleFrameOfScreen) {
            adjustedWindowRect.origin.y = visibleFrameOfScreen.maxY - adjustedWindowRect.height - CGFloat(Defaults.gapSize.value)
            if againstBottomScreenEdge(originalWindowRect, visibleFrameOfScreen) {
                adjustedWindowRect.size.height = visibleFrameOfScreen.height - (CGFloat(Defaults.gapSize.value) * 2)
            }
        }
        if againstBottomScreenEdge(originalWindowRect, visibleFrameOfScreen) {
            adjustedWindowRect.origin.y = visibleFrameOfScreen.minY + CGFloat(Defaults.gapSize.value)
        }
        return adjustedWindowRect
    }

}
