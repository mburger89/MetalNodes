import XCTest

/// The drag-and-drop and gesture checks no unit test can reach (spec §22.8). XCTest, not Swift
/// Testing: XCUITest has no Swift Testing surface. Every test launches with `-mnFixture <name>`, so
/// the document on screen is deterministic and its node ids are known.
@MainActor
final class MetalNodesAppUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    // MARK: Harness

    private func launch(fixture: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-mnFixture", fixture]
        #if os(macOS)
        // Without this AppKit restores the window — and the document — an earlier test left behind,
        // and the fixture never gets a chance to build a new one.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        #endif
        app.launch()
        let canvas = canvas(app)
        #if os(iOS)
        openFixtureDocument(app, canvas: canvas)
        #else
        // With persistence ignored there is nothing to restore, so whether AppKit opens an untitled
        // document at launch is up to it; File ▸ New makes one from the fixture either way.
        if !canvas.waitForExistence(timeout: 10) { app.typeKey("n", modifierFlags: .command) }
        #endif
        XCTAssertTrue(canvas.waitForExistence(timeout: 30), "the canvas never appeared")
        return app
    }

    #if os(iOS)
    /// iPadOS opens the document browser first, and Create Document is what builds a document from
    /// `LaunchFixture`. Two wrinkles the harness has to absorb: a document an earlier test left
    /// open is restored on launch — which would put the *previous* test's fixture on screen — so
    /// the browser is popped back to first; and the browser can still be settling when the button
    /// first resolves, so a tap that lands too early is simply repeated.
    private func openFixtureDocument(_ app: XCUIApplication, canvas: XCUIElement) {
        if canvas.waitForExistence(timeout: 5) {
            app.buttons["BackButton"].firstMatch.tap()
            _ = canvas.waitForNonExistence(timeout: 15)
        }
        let create = app.buttons["Create Document"]
        for _ in 0..<4 {
            guard create.waitForExistence(timeout: 15), create.isHittable else { return }
            create.tap()
            if canvas.waitForExistence(timeout: 15) { return }
        }
    }

    /// iPadOS presents `.inspector` as an overlay lying across the canvas's right-hand third, and
    /// `showsInspector` starts `true`: while it is open nothing under it is hittable and a canvas
    /// gesture aimed at the viewport centre lands in the inspector instead. Canvas gestures
    /// therefore run with it closed, and whatever has to be *read* from the inspector opens it
    /// again. macOS gives the same column its own `HSplitView` pane, where nothing overlaps.
    private func toggleInspector(_ app: XCUIApplication) {
        let button = app.buttons["toolbar.inspector"]
        XCTAssertTrue(button.waitForExistence(timeout: 10), "the inspector button is missing")
        button.tap()
    }
    #endif

    /// Frames the whole graph, so a node addressed by id is on screen whatever the window's size:
    /// the `textured` fixture's Fragment Output sits at x = 620, past the right edge of the canvas
    /// in both default layouts.
    private func zoomToFit(_ app: XCUIApplication) {
        #if os(iOS)
        app.buttons["toolbar.fit"].tap()
        #else
        // The View menu's canvas items are gated on canvas focus, which a click gives it.
        canvas(app).click()
        app.menuBars.menuBarItems["View"].click()
        app.menuBars.menuItems["Zoom to Fit"].click()
        #endif
    }

    /// Identifiers are set on containers whose element type differs by platform (a node is a group
    /// on macOS and an `Other` on iPadOS), so every lookup goes through `descendants`.
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// The canvas and the nodes on it: a group on macOS, an `Other` on iPadOS. Named by type rather
    /// than through `element(_:_:)` because these are polled in loops, and an `.any` descendant
    /// query costs a full accessibility snapshot every time.
    private func canvas(_ app: XCUIApplication) -> XCUIElement {
        #if os(macOS)
        app.groups["canvas"]
        #else
        app.otherElements["canvas"]
        #endif
    }

    private func nodeCount(_ app: XCUIApplication) -> Int {
        let nodes = NSPredicate(format: "identifier BEGINSWITH 'node.'")
        #if os(macOS)
        return app.groups.matching(nodes).count
        #else
        return app.otherElements.matching(nodes).count
        #endif
    }

    /// Polls, because a SwiftUI update lands a frame or two after the gesture ends.
    private func wait(_ timeout: TimeInterval = 5, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return condition()
    }

    /// The inspector's "N nodes selected" line — the only place the selection size is rendered as
    /// text. Shown for two or more nodes, which is exactly what the marquee tests assert.
    private func selectedNodeCount(_ app: XCUIApplication) -> Int {
        let query = app.staticTexts.matching(Self.text(endingWith: "nodes selected"))
        guard let label = query.allElementsBoundByIndex.first?.label,
              let n = Int(label.split(separator: " ").first ?? "") else { return 0 }
        return n
    }

    /// AppKit puts a `Text`'s string in the element's *value* and leaves the label empty, UIKit the
    /// other way round, so every text match has to accept either.
    private static func text(beginningWith s: String) -> NSPredicate {
        NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", s, s)
    }

    private static func text(endingWith s: String) -> NSPredicate {
        NSPredicate(format: "label ENDSWITH %@ OR value ENDSWITH %@", s, s)
    }

    // MARK: Tests

    #if os(macOS)
    /// Palette → canvas drag-in, the check M5 could not automate.
    func testPaletteDragPlacesANode() {
        let app = launch(fixture: "starter")
        let canvas = canvas(app)
        let row = element(app, "palette.input.time")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the Time row is not in the palette")
        let before = nodeCount(app)
        // A `.draggable` row hands AppKit a real drag session, which only starts once the pointer
        // has been held down and then moved slowly; the hold at the far end gives the canvas's
        // `dropDestination` time to accept before the button comes back up.
        centre(of: row).press(forDuration: 1,
                              thenDragTo: centre(of: canvas),
                              withVelocity: .slow,
                              thenHoldForDuration: 1)
        XCTAssertTrue(wait { self.nodeCount(app) == before + 1 },
                      "the drag placed \(nodeCount(app) - before) nodes, expected 1")
    }
    #endif

    #if os(iOS)
    /// One tap on a palette row places at the viewport centre (spec §22.3).
    func testTapToPlaceOnIPad() {
        let app = launch(fixture: "starter")
        let row = element(app, "palette.input.time")
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the Time row is not in the palette")
        let before = nodeCount(app)
        row.tap()
        XCTAssertTrue(wait { self.nodeCount(app) == before + 1 },
                      "the tap placed \(nodeCount(app) - before) nodes, expected 1")
    }

    /// Pinch zooms the canvas: the same node draws wider afterwards.
    func testPinchZooms() {
        let app = launch(fixture: "textured")
        toggleInspector(app)
        let node = element(app, "node.00000101")
        XCTAssertTrue(node.waitForExistence(timeout: 10))
        let before = node.frame.width
        canvas(app).pinch(withScale: 2, velocity: 1)
        XCTAssertTrue(wait { node.frame.width > before * 1.3 },
                      "the node is \(node.frame.width) pt wide, was \(before) pt")
    }

    /// Lasso mode: a drag across the graph replaces the selection with what it crossed.
    func testLassoSelects() {
        let app = launch(fixture: "sample")
        toggleInspector(app)
        // A segmented `Picker`'s segments carry the SF Symbol's identifier, not their `Label`'s
        // text, so the lasso segment is `lasso` rather than "Lasso".
        let lasso = element(app, "toolbar.mode").buttons["lasso"]
        XCTAssertTrue(lasso.waitForExistence(timeout: 10), "the canvas-mode picker is missing")
        lasso.tap()
        let canvas = canvas(app)
        // From the empty bottom-left corner: a drag that *starts* on a node moves it in every
        // mode, lasso included (`TouchIntentMapper.dragChanged`), and the graph sits top-left.
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.95))
            .press(forDuration: 0.1,
                   thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.05)))
        toggleInspector(app)
        XCTAssertTrue(wait { self.selectedNodeCount(app) >= 2 },
                      "the lasso selected \(selectedNodeCount(app)) nodes, expected at least 2")
    }
    #endif

    /// Long-press (iPad) / right-click (macOS) opens the canvas menu (spec §22.3).
    func testLongPressOpensTheContextMenu() {
        let app = launch(fixture: "sample")
        let canvas = canvas(app)
        #if os(iOS)
        toggleInspector(app)
        canvas.press(forDuration: 0.6)
        // The iPad menu is a popover of SwiftUI buttons; macOS gets a real `NSMenu`.
        let addSticky = app.buttons["Add Sticky Note"]
        #else
        canvas.rightClick()
        let addSticky = app.menuItems["Add Sticky Note"]
        #endif
        XCTAssertTrue(addSticky.waitForExistence(timeout: 5),
                      "the context menu did not appear")
    }

    /// A wire drawn by hand: the fixture's Texture Sample output onto the Fragment Output's body,
    /// which auto-connects to its `color` input. Read back through the inspector, where a connected
    /// input row reads "← <source>".
    func testWireDragConnects() {
        let app = launch(fixture: "textured")
        let out = element(app, "node.00000103")
        let socket = element(app, "socket.00000102.color")
        XCTAssertTrue(out.waitForExistence(timeout: 10), "the Fragment Output is not on the canvas")
        XCTAssertTrue(socket.waitForExistence(timeout: 10), "the Texture Sample's colour socket is not on the canvas")

        let connected = app.staticTexts.matching(Self.text(beginningWith: "← "))
        #if os(iOS)
        toggleInspector(app)
        #endif
        zoomToFit(app)
        header(of: out).tap()
        #if os(iOS)
        toggleInspector(app)
        #endif
        XCTAssertFalse(connected.firstMatch.waitForExistence(timeout: 2),
                       "the Fragment Output already has a connected input")

        #if os(iOS)
        toggleInspector(app)
        #endif
        centre(of: socket).press(forDuration: 0.15, thenDragTo: header(of: out))
        header(of: out).tap()
        #if os(iOS)
        toggleInspector(app)
        #endif
        XCTAssertTrue(connected.firstMatch.waitForExistence(timeout: 5),
                      "no wire arrived at the Fragment Output")
    }

    /// A node's header strip. Its *centre* is a param control on most nodes — an interactive rect
    /// the iPad's touch overlay deliberately hands back to SwiftUI (spec §22.2) — so a tap there
    /// edits a value instead of selecting the node.
    private func header(of node: XCUIElement) -> XCUICoordinate {
        node.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
    }

    /// A socket's centre. Coordinates rather than the element itself, because only `XCUICoordinate`
    /// can be dragged to another coordinate on both platforms.
    private func centre(of element: XCUIElement) -> XCUICoordinate {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
    }
}
