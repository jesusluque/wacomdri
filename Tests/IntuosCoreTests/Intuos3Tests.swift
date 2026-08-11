// SPDX-License-Identifier: GPL-2.0-or-later
import Testing
@testable import IntuosCore

@Test func deviceConstantsMatchLinuxFeatureTable() {
    #expect(Intuos3.vendorID == 0x056A)
    #expect(Intuos3.productID == 0x00B1)
    #expect(Intuos3.maxX == 40640)
    #expect(Intuos3.maxY == 30480)
    // 40640 / 200 = 203.2 mm, 30480 / 200 = 152.4 mm -> the nominal 8x6 inches.
    #expect(Intuos3.activeAreaMM.width == 203.2)
    #expect(Intuos3.activeAreaMM.height == 152.4)
}
