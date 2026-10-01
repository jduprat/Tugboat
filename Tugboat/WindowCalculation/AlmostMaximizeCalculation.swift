/// AlmostMaximizeCalculation.swift

import Foundation

class AlmostMaximizeCalculation: WindowCalculation {
    
    // This calculation is a shared instance; preferences remain editable.
    var almostMaximizeHeight: CGFloat {
        let value = Defaults.almostMaximizeHeight.value
        return (value <= 0 || value > 1) ? 0.9 : CGFloat(value)
    }

    var almostMaximizeWidth: CGFloat {
        let value = Defaults.almostMaximizeWidth.value
        return (value <= 0 || value > 1) ? 0.9 : CGFloat(value)
    }
    
    override func calculate(_ params: WindowCalculationParameters) -> WindowCalculationResult? {
        RepeatedMaximizeRestore.calculate(params) ?? super.calculate(params)
    }
    
    override func calculateRect(_ params: RectCalculationParameters) -> RectResult {

        let visibleFrameOfScreen = params.visibleFrameOfScreen
        var calculatedWindowRect = visibleFrameOfScreen
        
        // Resize
        calculatedWindowRect.size.height = round(visibleFrameOfScreen.height * almostMaximizeHeight)
        calculatedWindowRect.size.width = round(visibleFrameOfScreen.width * almostMaximizeWidth)
        
        // Center
        calculatedWindowRect.origin.x = round((visibleFrameOfScreen.width - calculatedWindowRect.width) / 2.0) + visibleFrameOfScreen.minX
        calculatedWindowRect.origin.y = round((visibleFrameOfScreen.height - calculatedWindowRect.height) / 2.0) + visibleFrameOfScreen.minY
        
        return RectResult(calculatedWindowRect)
    }
    
}
