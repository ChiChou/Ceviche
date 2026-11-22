import XCTest
import CevicheTestSupport
import AppKit
import SwiftUI
import MapKit
import CevicheCore
@testable import CevicheMac

final class CatalogMapTests: XCTestCase {
    @MainActor func testMapCollectionLoadsBeyondGridPageAndKeepsFiltersScoped() async throws {
        let (directory, model, _) = try await EditorFixtures.catalog()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try XCTUnwrap(model.store)
        var template = model.assets[0].asPhoto
        template.latitude = 0; template.longitude = 0 // Valid equator/prime-meridian coordinates.
        template.rating = 4
        for index in 0..<501 {
            var photo = template
            photo.id = "located-\(index)"; photo.importPath += "-\(index)"
            _ = try await store.insert(photo, thumbnail: nil)
        }
        // Exclude photos without a complete location and those in Trash.
        var incomplete = template
        incomplete.id = "incomplete"; incomplete.importPath += "-incomplete"; incomplete.longitude = nil
        _ = try await store.insert(incomplete, thumbnail: nil)
        var trashed = template
        trashed.id = "trashed"; trashed.importPath += "-trashed"; trashed.trashedAt = Date()
        _ = try await store.insert(trashed, thumbnail: nil)
        await model.showCollection(trash: false, geotagged: true)
        XCTAssertEqual(model.shownOverview, .map); XCTAssertTrue(model.filter.geotagged)
        XCTAssertEqual(model.assets.count, 501)
        model.filter.minimumRating = 5; await model.refresh()
        XCTAssertTrue(model.assets.isEmpty)
        model.clearFilters(); await model.refresh()
        XCTAssertTrue(model.filter.geotagged); XCTAssertEqual(model.assets.count, 501)
        await model.showCollection(trash: true)
        XCTAssertFalse(model.filter.geotagged); XCTAssertNil(model.shownOverview)
        XCTAssertEqual(model.assets.map(\.id), [trashed.id])
        await model.showCollection(trash: false)
        XCTAssertNil(model.shownOverview); XCTAssertFalse(model.filter.geotagged)
        XCTAssertEqual(model.assets.count, 500)
        XCTAssertNil(model.error)
    }

    /// Map, a pin's photos in the wall or the grid, and back up.
    @MainActor func testAPinOpensItsPhotosAndCommandUpReturnsToTheMap() async throws {
        let (directory, model, editor) = try await EditorFixtures.catalog()
        defer { try? FileManager.default.removeItem(at: directory); editor.closeDocument() }
        let store = try XCTUnwrap(model.store)
        let template = model.assets[0].asPhoto
        for (index, place) in [(48.8566, 2.3522), (48.8567, 2.3523), (35.6762, 139.6503)].enumerated() {
            var photo = template; photo.latitude = place.0; photo.longitude = place.1
            photo.id = "placed-\(index)"; photo.importPath += "-\(index)"
            _ = try await store.insert(photo, thumbnail: nil)
        }
        await model.showCollection(trash: false, geotagged: true)
        XCTAssertEqual(model.shownOverview, .map); XCTAssertEqual(model.assets.count, 3)
        // G from the Map shows all of its photos.
        model.pressGrid(editor: editor)
        XCTAssertNil(model.shownOverview); XCTAssertTrue(model.showingPhotos); XCTAssertEqual(model.assets.count, 3)
        await model.goUp()
        XCTAssertEqual(model.shownOverview, .map)
        // The Paris pin: two photos.
        await model.openPlace(model.assets.filter { $0.id != "placed-2" })
        XCTAssertNotNil(model.filter.mapArea); XCTAssertTrue(model.showingPhotos)
        XCTAssertEqual(Set(model.assets.map(\.id)), ["placed-0", "placed-1"])
        XCTAssertEqual(model.collectionOverview, .map)
        model.showPhotos(.wall, editor: editor)
        XCTAssertEqual(model.gridStyle, .wall); XCTAssertNil(model.shownOverview)
        await model.goUp()
        XCTAssertNil(model.filter.mapArea); XCTAssertEqual(model.shownOverview, .map); XCTAssertEqual(model.assets.count, 3)
        // Other collections have no overview.
        await model.showCollection(trash: false)
        XCTAssertNil(model.collectionOverview); XCTAssertTrue(model.showingPhotos)
    }
}

final class CatalogPeopleNavigationTests: XCTestCase {
    /// People, a person's faces or photos, and back up; without the model the overview is the Faces wall.
    @MainActor func testAPersonOpensFromPeopleAndCommandUpReturns() async throws {
        let (directory, model, editor) = try await EditorFixtures.catalog()
        defer { try? FileManager.default.removeItem(at: directory); editor.closeDocument() }
        // Navigation only: which photos a person holds is CatalogPeopleTests'.
        let person = "someone"
        model.peopleStatus.available = false
        await model.showCollection(area: .library, faces: true)
        XCTAssertEqual(model.shownOverview, .faces)
        model.peopleStatus.available = true
        XCTAssertEqual(model.shownOverview, .people)
        await model.openPerson(person)
        XCTAssertEqual(model.filter.personID, person); XCTAssertNil(model.shownOverview)
        XCTAssertTrue(model.showingPersonFaces); XCTAssertFalse(model.showingPhotos)
        // ⌘2 shows the person's photos in the grid.
        model.showPhotos(.tiles, editor: editor)
        XCTAssertFalse(model.showingPersonFaces); XCTAssertTrue(model.showingPhotos); XCTAssertEqual(model.filter.personID, person)
        model.showOverview(editor: editor)
        for _ in 0..<300 where model.filter.personID != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(model.filter.personID); XCTAssertEqual(model.shownOverview, .people)
        // From the overview G opens the collection's photos.
        model.pressGrid(editor: editor)
        XCTAssertNil(model.shownOverview); XCTAssertTrue(model.showingPhotos); XCTAssertTrue(model.filter.withFaces)
    }
}
