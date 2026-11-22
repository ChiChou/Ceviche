import XCTest
import CoreImage
import ImageIO
import Metal
import Darwin
@testable import CevicheCore

final class MCPTests: XCTestCase {
    func testSchemaCoversEveryNumericControlAndRejectsUnknownNestedFields() throws {
        let defaults = try MCPSchema.encoded(Adjustments())
        let fields = MCPEditSchema.global["properties"] as! [String: Any]
        XCTAssertEqual(Set(defaults.keys).subtracting(["masks"]), Set(fields.keys).subtracting(["look", "cameraProfile", "lut"]))
        let pixels = try MCPSchema.encoded(PixelAdjustments())
        XCTAssertEqual(Set(pixels.keys), Set((MCPEditSchema.pixels["properties"] as! [String: Any]).keys))
        XCTAssertThrowsError(try MCPEditSchema.apply(["global": ["grain": ["strength": 20]]], to: Adjustments(), isRAW: true)) { error in
            XCTAssertEqual((error as? MCPFailure)?.path, "changes.global.grain.strength")
        }
        XCTAssertThrowsError(try MCPEditSchema.apply(["global": ["exposure": true]], to: Adjustments(), isRAW: true))
        XCTAssertThrowsError(try MCPEditSchema.apply(["global": ["exposure": "0.2"]], to: Adjustments(), isRAW: true))
        XCTAssertThrowsError(try MCPEditSchema.apply(["global": ["quarterTurns": 1.5]], to: Adjustments(), isRAW: true))
        XCTAssertThrowsError(try MCPEditSchema.apply(["global": ["exposure": 10]], to: Adjustments(), isRAW: true))
    }
    func testSparsePatchPreservesDisabledControlsMasksAndEmbeddedData() throws {
        var base = Adjustments(); base.exposure = 0.8; base.grain.amount = 35; base.disabledSections = [.grain]
        var mask = PhotoMask(kind: .sky); mask.raster = Data([1, 2, 3]); mask.adjustments.exposure = -0.5
        base.masks = [mask]
        let result = try MCPEditSchema.apply(["global": ["highlights": -20], "masks": [mask.id.uuidString: ["adjustments": ["shadows": 15]]]], to: base, isRAW: true)
        XCTAssertEqual(result.exposure, 0.8); XCTAssertEqual(result.highlights, -20)
        XCTAssertEqual(result.grain.amount, 35); XCTAssertEqual(result.disabledSections, [.grain])
        XCTAssertEqual(result.masks[0].raster, mask.raster); XCTAssertEqual(result.masks[0].adjustments.exposure, -0.5)
        XCTAssertEqual(result.masks[0].adjustments.shadows, 15)
        XCTAssertEqual(base.highlights, 0)
        let state = try MCPEditSchema.state(base, defaults: Adjustments())
        let visible = (state["masks"] as! [[String: Any]])[0]
        XCTAssertNil(visible["raster"]); XCTAssertEqual(visible["rasterPresent"] as? Bool, true)
    }
    func testInvalidBatchDoesNotChangeOriginalAndContextRulesApply() throws {
        var base = Adjustments(); base.exposure = 0.2
        XCTAssertThrowsError(try MCPEditSchema.apply(["global": ["exposure": 0.7, "geometry": ["crop": ["x": 0.9, "width": 0.8]]]], to: base, isRAW: true))
        XCTAssertEqual(base.exposure, 0.2)
        XCTAssertThrowsError(try MCPEditSchema.apply(["global": ["temperature": 5000]], to: base, isRAW: false))
        XCTAssertThrowsError(try MCPEditSchema.apply(["masks": [UUID().uuidString: ["opacity": 0.5]]], to: base, isRAW: true))
        XCTAssertThrowsError(try MCPEditSchema.apply(["global": ["curve": [["x": 0, "y": 0], ["x": 0.5, "y": 1]]]], to: base, isRAW: true))
        XCTAssertThrowsError(try MCPEditSchema.apply(["global": ["colorProfile": ["iccData": "anything"]]], to: base, isRAW: true))
    }
    func testMaskCreationReorderRemovalAndDuplicateValidation() throws {
        let id = UUID().uuidString
        let added = try MCPEditSchema.apply(["addMasks": [["id": id, "kind": "Linear gradient", "name": "Foreground", "adjustments": ["exposure": 0.4]]]], to: Adjustments(), isRAW: true)
        XCTAssertEqual(added.masks.count, 1); XCTAssertEqual(added.masks[0].adjustments.exposure, 0.4)
        XCTAssertThrowsError(try MCPEditSchema.apply(["addMasks": [["id": id, "kind": "Brush"]]], to: added, isRAW: true))
        XCTAssertThrowsError(try MCPEditSchema.apply(["maskOrder": []], to: added, isRAW: true))
        let subjectID = UUID().uuidString
        XCTAssertThrowsError(try MCPEditSchema.apply(["addMasks": [["id": subjectID, "kind": "Subject"]]], to: added, isRAW: true)) { error in
            XCTAssertEqual((error as? MCPFailure)?.code, "selection_required")
        }
        var selection = PhotoMask(kind: .subject); selection.raster = Data([9, 9, 9])
        XCTAssertEqual(MCPEditSchema.generatedAdditions(["addMasks": [["id": subjectID, "kind": "Object", "point": ["x": 0.25, "y": 0.75]], ["id": id, "kind": "Brush"]]]).map(\.kind), [.object])
        let generated = try MCPEditSchema.apply(["addMasks": [["id": subjectID, "kind": "Subject", "name": "Church", "point": ["x": 0.5, "y": 0.5], "adjustments": ["exposure": 0.3]]]],
                                                to: added, isRAW: true, generated: [subjectID.lowercased(): selection])
        XCTAssertEqual(generated.masks.count, 2); XCTAssertEqual(generated.masks[1].id.uuidString, subjectID)
        XCTAssertEqual(generated.masks[1].kind, .subject); XCTAssertEqual(generated.masks[1].raster, selection.raster)
        XCTAssertEqual(generated.masks[1].name, "Church"); XCTAssertEqual(generated.masks[1].adjustments.exposure, 0.3)
        let partID = UUID().uuidString, aiPartID = UUID().uuidString
        let compound = try MCPEditSchema.apply(["masks": [id: ["components": [["id": partID, "operation": "Subtract", "selection": ["kind": "Linear gradient", "start": ["x": 0.5, "y": 0.2], "feather": 0.1]]]]]], to: added, isRAW: true)
        XCTAssertEqual(compound.masks[0].components.count, 1); XCTAssertEqual(compound.masks[0].components[0].operation, .subtract)
        XCTAssertEqual(compound.masks[0].components[0].selection.start.y, 0.2); XCTAssertEqual(compound.masks[0].components[0].selection.feather, 0.1)
        XCTAssertThrowsError(try MCPEditSchema.apply(["masks": [id: ["components": [["id": UUID().uuidString, "operation": "Add"]]]]], to: added, isRAW: true))
        var withRaster = compound; withRaster.masks[0].components[0].selection.raster = Data([4, 2])
        XCTAssertEqual(MCPEditSchema.generatedAdditions(["masks": [id: ["components": [["id": partID, "operation": "Add", "selection": ["kind": "Sky"]], ["id": aiPartID, "operation": "Intersect", "selection": ["kind": "Sky"]]]]]], existing: withRaster).map(\.id), [aiPartID], "Only new components are generated")
        XCTAssertThrowsError(try MCPEditSchema.apply(["masks": [id: ["components": [["id": aiPartID, "operation": "Intersect", "selection": ["kind": "Sky"]]]]]], to: withRaster, isRAW: true)) { error in
            XCTAssertEqual((error as? MCPFailure)?.code, "selection_required")
        }
        var sky = PhotoMask(kind: .sky); sky.raster = Data([7])
        let repatched = try MCPEditSchema.apply(["masks": [id: ["components": [["id": partID, "operation": "Add"], ["id": aiPartID, "operation": "Intersect", "selection": ["kind": "Sky"]]]]]], to: withRaster, isRAW: true, generated: [aiPartID.lowercased(): sky])
        XCTAssertEqual(repatched.masks[0].components.count, 2)
        XCTAssertEqual(repatched.masks[0].components[0].operation, .add); XCTAssertEqual(repatched.masks[0].components[0].selection.raster, Data([4, 2]), "A listed component keeps its raster")
        XCTAssertEqual(repatched.masks[0].components[1].selection.kind, .sky); XCTAssertEqual(repatched.masks[0].components[1].selection.raster, Data([7]))
        let cleared = try MCPEditSchema.apply(["masks": [id: ["components": []]]], to: repatched, isRAW: true)
        XCTAssertTrue(cleared.masks[0].components.isEmpty)
        let removed = try MCPEditSchema.apply(["removeMasks": [id]], to: added, isRAW: true)
        XCTAssertTrue(removed.masks.isEmpty)
        var masked = Adjustments(); var mask = PhotoMask(kind: .linear)
        mask.id = UUID(uuidString: "00000000-0000-0000-0000-00000000000a")!; masked.masks = [mask]
        XCTAssertThrowsError(try MCPEditSchema.apply(["masks": [mask.id.uuidString.uppercased(): ["opacity": 0.5], mask.id.uuidString.lowercased(): ["opacity": 0.8]]], to: masked, isRAW: true))
    }
    func testRevisionTracksHiddenDataMetadataAndDisabledState() throws {
        var a = Adjustments(); var m = CatalogMetadata()
        let first = try MCPEditSchema.revision(a, metadata: m)
        a.disabledSections = [.grain, .detail]
        let disabled = try MCPEditSchema.revision(a, metadata: m)
        XCTAssertNotEqual(first, disabled)
        a.disabledSections = [.detail, .grain]
        XCTAssertEqual(disabled, try MCPEditSchema.revision(a, metadata: m))
        m.rating = 4
        XCTAssertNotEqual(disabled, try MCPEditSchema.revision(a, metadata: m))
    }
    func testHarnessSchemaRequiresEnvelopeAndMatchesHandlerRanges() throws {
        let valid: [String: Any] = ["catalogId": "c", "assetId": "a", "expectedRevision": "r", "schemaVersion": "1", "changes": ["global": ["exposure": 0.3]]]
        try MCPSchema.validate(valid, against: MCPEditSchema.document)
        var wrong = valid; wrong["schemaVersion"] = "2"
        XCTAssertThrowsError(try MCPSchema.validate(wrong, against: MCPEditSchema.document))
        wrong = valid; wrong["changes"] = ["global": ["exposure": 6]]
        XCTAssertThrowsError(try MCPSchema.validate(wrong, against: MCPEditSchema.document))
        let toolSchema = MCPTools.all.first { $0.name == "photo_apply" }!.input
        XCTAssertLessThan(try MCPSchema.data(toolSchema).count, 1000)
        XCTAssertFalse(MCPTools.all.contains { $0.name.contains("delete") || $0.name.contains("execute") })
    }
    func testHTTPFramingAndOriginChecks() throws {
        let body = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}"
        let prefix = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:18432\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n"
        XCTAssertNil(try MCPHTTPRequest.parse(Data(prefix.utf8)))
        let request = try XCTUnwrap(MCPHTTPRequest.parse(Data((prefix + body).utf8)))
        XCTAssertEqual(request.body, Data(body.utf8))
        XCTAssertNil(request.originStatus(port: 18432))
        XCTAssertEqual(request.originStatus(port: 19999), 403)
        let hostile = prefix.replacingOccurrences(of: "Content-Type:", with: "Origin: https://evil.example\r\nContent-Type:") + body
        XCTAssertEqual(try XCTUnwrap(MCPHTTPRequest.parse(Data(hostile.utf8))).originStatus(port: 18432), 403)
        let duplicate = prefix.replacingOccurrences(of: "Content-Type:", with: "Content-Length: 0\r\nContent-Type:") + body
        XCTAssertThrowsError(try MCPHTTPRequest.parse(Data(duplicate.utf8)))
        XCTAssertThrowsError(try MCPHTTPRequest.parse(Data((prefix + body + "extra").utf8)))
        XCTAssertThrowsError(try MCPHTTPRequest.parse(Data("POST /mcp HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n".utf8)))
    }
    func testPreviewUsesNativeRegionPixelsAndNeverEnlarges() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("Metal unavailable") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source.png")
        let context = try XCTUnwrap(CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 1600, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 100, width: 400, height: 100))
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 400, height: 100))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
        let renderer = try RawRenderer(sourceURL: source)
        let preview = try await renderer.mcpPreview(renderer.info.defaults, scale: 1, maxEdge: 1600, scope: [0, 0, 0.25, 0.25])
        XCTAssertEqual(preview.width, 100); XCTAssertEqual(preview.height, 50); XCTAssertEqual(preview.region, [0, 0, 100, 50])
        let encoded = try XCTUnwrap(CGImageSourceCreateWithData(preview.png as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(encoded, 0, nil))
        let sample = try XCTUnwrap(CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        sample.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let bytes = try XCTUnwrap(sample.data).assumingMemoryBound(to: UInt8.self)
        XCTAssertGreaterThan(bytes[0], bytes[2], "Top-left scope must show the red top half")
        let whole = try await renderer.mcpPreview(renderer.info.defaults, scale: 0.25, maxEdge: 1600)
        XCTAssertEqual(whole.statistics.red.mean, 0.5, accuracy: 0.02); XCTAssertEqual(whole.statistics.blue.mean, 0.5, accuracy: 0.02)
        XCTAssertLessThan(whole.statistics.green.maximum, whole.statistics.red.maximum)
        XCTAssertGreaterThan(whole.statistics.whiteFraction, 0.85); XCTAssertEqual(whole.statistics.blackFraction, 0)
        var gradient = PhotoMask(kind: .linear); gradient.selection.start = MaskPoint(x: 0.5, y: 0.5); gradient.selection.end = MaskPoint(x: 0.5, y: 0.5001)
        var masked = renderer.info.defaults; masked.masks = [gradient]
        let matte = try await renderer.mcpPreview(masked, scale: 0.25, maxEdge: 1600, content: .matte(gradient))
        XCTAssertEqual(matte.width, 100); XCTAssertEqual(matte.height, 50)
        XCTAssertEqual(matte.statistics.luminance.mean, 0.5, accuracy: 0.05, "A gradient starting at mid height covers half the frame")
        XCTAssertLessThan(matte.statistics.red.percentiles[25]!, 0.05); XCTAssertGreaterThan(matte.statistics.red.percentiles[75]!, 0.95)
        var turned = masked; turned.quarterTurns = 1
        let rotated = try await renderer.mcpPreview(turned, scale: 0.25, maxEdge: 1600, content: .matte(gradient))
        XCTAssertEqual(rotated.width, 50); XCTAssertEqual(rotated.height, 100, "Matte follows the developed geometry")
        let overlay = try await renderer.mcpPreview(masked, scale: 0.25, maxEdge: 1600, content: .overlay(gradient))
        XCTAssertEqual(overlay.width, 100); XCTAssertGreaterThan(overlay.statistics.red.mean, whole.statistics.red.mean)
        let reduced = try await renderer.mcpPreview(renderer.info.defaults, scale: 0.5, maxEdge: 1600, scope: [0, 0, 0.25, 0.25])
        XCTAssertEqual(reduced.width, 50); XCTAssertEqual(reduced.height, 25)
        do { _ = try await renderer.mcpPreview(renderer.info.defaults, scale: 2); XCTFail("Upscaling accepted") } catch { }
        let original = try Data(contentsOf: source)
        var export = ExportSettings(); export.select(.png)
        do { try await renderer.export(to: source, adjustments: renderer.info.defaults, settings: export, overwriteExisting: false); XCTFail("Overwrote original") } catch { }
        XCTAssertEqual(try Data(contentsOf: source), original)
        let target = dir.appendingPathComponent("existing.png"); try Data("keep".utf8).write(to: target)
        do { try await renderer.export(to: target, adjustments: renderer.info.defaults, settings: export, overwriteExisting: false); XCTFail("Overwrote existing export") } catch { }
        XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8))
    }

    func testStatisticsReportHistogramPercentilesClippingAndSaturation() {
        // Four pixels: black, white, mid grey, saturated red.
        let bytes: [UInt8] = [0, 0, 0, 255,  255, 255, 255, 255,  128, 128, 128, 255,  255, 0, 0, 255]
        let stats = MCPStatistics(rgba: bytes, width: 2, height: 2)
        XCTAssertEqual(stats.pixels, 4)
        XCTAssertEqual(stats.blackFraction, 0.25); XCTAssertEqual(stats.whiteFraction, 0.5)
        XCTAssertEqual(stats.clippedChannels, [0.5, 0.25, 0.25])
        XCTAssertEqual(stats.red.minimum, 0); XCTAssertEqual(stats.red.maximum, 1)
        XCTAssertEqual(stats.red.mean, (255 + 128 + 255) / 4 / 255, accuracy: 0.001)
        XCTAssertEqual(stats.green.percentiles[50]!, 128 / 255, accuracy: 0.001)
        XCTAssertEqual(stats.meanSaturation, 1.0 / 3, accuracy: 0.0001, "Black pixels are excluded from saturation"); XCTAssertEqual(stats.saturationP95, 1)
        XCTAssertEqual(MCPStatistics(rgba: [3, 0, 0, 255], width: 1, height: 1).meanSaturation, 0, "Noise-level pixels do not count as saturated")
        XCTAssertEqual(stats.red.histogram.count, MCPStatistics.bins)
        XCTAssertEqual(stats.red.histogram.reduce(0, +), 1, accuracy: 0.0001)
        XCTAssertEqual(stats.red.histogram[0], 0.25); XCTAssertEqual(stats.red.histogram[MCPStatistics.bins - 1], 0.5)
        let json = stats.json
        XCTAssertEqual(((json["clipping"] as? [String: Any])?["white"] as? Double), 0.5)
        XCTAssertNotNil((json["luminance"] as? [String: Any])?["p99"])
        XCTAssertNoThrow(try MCPSchema.data(json))
    }
    func testTokenFileIsPrivateAndComparedExactly() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("mcp-token")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let token = try MCPToken.loadOrCreate(at: url)
        XCTAssertEqual(token.count, 64)
        XCTAssertEqual(try MCPToken.loadOrCreate(at: url), token)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        XCTAssertTrue(MCPToken.authorizes("Bearer \(token)", token: token))
        XCTAssertTrue(MCPToken.authorizes("bearer \(token)", token: token))
        XCTAssertFalse(MCPToken.authorizes(nil, token: token))
        XCTAssertFalse(MCPToken.authorizes("Bearer \(token.dropLast())", token: token))
        XCTAssertFalse(MCPToken.authorizes("Basic \(token)", token: token))
        let replaced = try MCPToken.regenerate(at: url)
        XCTAssertNotEqual(replaced, token)
        XCTAssertEqual(MCPToken.read(at: url), replaced)
    }
    func testLiveHTTPRequiresTokenAndChecksSessionAndOrigin() async throws {
        let ready = expectation(description: "Listener ready"); ready.assertForOverFulfill = false
        let port = Int.random(in: 40000...59000)
        let token = String(repeating: "ab", count: 32)
        let server = try MCPHTTPServer(port: port, token: token, handler: { data, session in
            let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            guard let id = request["id"] else { return nil }
            return try? MCPSchema.data(["jsonrpc": "2.0", "id": id, "result": ["session": session]])
        }, status: { _ in ready.fulfill() })
        defer { server.stop() }
        await fulfillment(of: [ready], timeout: 10)
        let configuration = URLSessionConfiguration.ephemeral; configuration.connectionProxyDictionary = [:]
        let client = URLSession(configuration: configuration)
        defer { client.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try MCPSchema.data(["jsonrpc": "2.0", "id": 1, "method": "initialize"])
        let (_, anonymous) = try await client.data(for: request)
        XCTAssertEqual((anonymous as? HTTPURLResponse)?.statusCode, 401)
        request.setValue("Bearer " + String(repeating: "cd", count: 32), forHTTPHeaderField: "Authorization")
        let (_, wrongToken) = try await client.data(for: request)
        XCTAssertEqual((wrongToken as? HTTPURLResponse)?.statusCode, 401)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, initialized) = try await client.data(for: request)
        XCTAssertEqual((initialized as? HTTPURLResponse)?.statusCode, 200)
        let sessionID = try XCTUnwrap((initialized as? HTTPURLResponse)?.value(forHTTPHeaderField: "MCP-Session-Id"))
        request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id")
        request.httpBody = try MCPSchema.data(["jsonrpc": "2.0", "method": "notifications/initialized"])
        let (empty, notification) = try await client.data(for: request)
        XCTAssertEqual((notification as? HTTPURLResponse)?.statusCode, 202); XCTAssertTrue(empty.isEmpty)
        request.setValue("https://evil.example", forHTTPHeaderField: "Origin")
        let (_, forbidden) = try await client.data(for: request)
        XCTAssertEqual((forbidden as? HTTPURLResponse)?.statusCode, 403)
        request.setValue(nil, forHTTPHeaderField: "Origin")
        request.setValue("unknown-session", forHTTPHeaderField: "MCP-Session-Id")
        let (_, missingSession) = try await client.data(for: request)
        XCTAssertEqual((missingSession as? HTTPURLResponse)?.statusCode, 404)
        request.setValue(sessionID, forHTTPHeaderField: "MCP-Session-Id")
        request.httpMethod = "GET"; request.httpBody = nil
        let (_, stream) = try await client.data(for: request)
        XCTAssertEqual((stream as? HTTPURLResponse)?.statusCode, 405)
    }

    func testStdioAdapterRepliesWithoutWaitingForEOF() async throws {
        let executable = Bundle(for: MCPTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("ceviche-mcp")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw XCTSkip("Build ceviche-mcp beside the test bundle") }
        let ready = expectation(description: "Adapter test listener ready"); ready.assertForOverFulfill = false
        let port = Int.random(in: 40000...59000)
        let token = String(repeating: "ef", count: 32)
        let server = try MCPHTTPServer(port: port, token: token, handler: { data, _ in
            let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            return try? MCPSchema.data(["jsonrpc": "2.0", "id": request["id"] ?? NSNull(), "result": [:]])
        }, status: { _ in ready.fulfill() })
        defer { server.stop() }
        await fulfillment(of: [ready], timeout: 10)
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = executable; process.standardInput = input; process.standardOutput = output; process.standardError = Pipe()
        process.environment = ProcessInfo.processInfo.environment.merging(["CEVICHE_MCP_PORT": String(port), "CEVICHE_MCP_TOKEN": token]) { _, b in b }
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        var buffered = Data()
        for id in 1...2 {
            var message = try MCPSchema.data(["jsonrpc": "2.0", "id": id, "method": id == 1 ? "initialize" : "ping"])
            message.append(10); try input.fileHandleForWriting.write(contentsOf: message)
            while buffered.firstIndex(of: 10) == nil {
                var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                guard poll(&descriptor, 1, 6000) > 0 else { XCTFail("Adapter buffered the request instead of replying while stdin remained open"); return }
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
                guard count > 0 else { XCTFail("Adapter closed stdout unexpectedly"); return }
                buffered.append(contentsOf: bytes.prefix(count))
            }
            let newline = buffered.firstIndex(of: 10)!
            let response = try JSONSerialization.jsonObject(with: Data(buffered[..<newline])) as! [String: Any]
            buffered.removeSubrange(...newline)
            XCTAssertEqual(response["id"] as? Int, id)
        }
        try input.fileHandleForWriting.close()
    }
}
