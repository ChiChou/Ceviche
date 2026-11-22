import XCTest
import CevicheCore
@testable import CevicheMac

final class ProTests: XCTestCase {
    func testProductIDsComeFromTheBuildAndACommunityBuildHasNone() {
        XCTAssertEqual(BuildFeatures.storeProducts(from: nil), [])
        XCTAssertEqual(BuildFeatures.storeProducts(from: ""), [])
        XCTAssertEqual(BuildFeatures.storeProducts(from: "a.pro, a.other,a.pro"), ["a.pro", "a.other"])
        XCTAssertEqual(BuildFeatures.storeProducts, [], "The committed Info.plist names no product")
    }
    func testOnlyAnUnrefundedPurchaseOfThisBuildsProductCounts() {
        let products: Set = ["p.pro"]
        XCTAssertEqual(Pro.access(productIDs: [], entitlements: [.init(productID: "p.pro")]), .community)
        XCTAssertEqual(Pro.access(productIDs: products, entitlements: []), .unpaid)
        XCTAssertEqual(Pro.access(productIDs: products, entitlements: [.init(productID: "p.pro")]), .purchased)
        XCTAssertEqual(Pro.access(productIDs: products, entitlements: [.init(productID: "p.pro", revoked: true)]), .unpaid, "Refunded")
        XCTAssertEqual(Pro.access(productIDs: products, entitlements: [.init(productID: "other.app")]), .unpaid)
    }
    @MainActor func testBadgeShowsOnlyWhenStoreKitSaysUnpaid() {
        XCTAssertFalse(Pro(productIDs: []).showsBadge)
        XCTAssertFalse(Pro(productIDs: []).sells)
        XCTAssertFalse(Pro(productIDs: ["p"]).showsBadge, "No badge until StoreKit answers")
        XCTAssertTrue(Pro(productIDs: ["p"], access: .unpaid).showsBadge)
        XCTAssertFalse(Pro(productIDs: ["p"], access: .purchased).showsBadge)
    }
}
