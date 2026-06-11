// MenuDescriptorTests.swift
// nacreTests

import XCTest
@testable import nacreLib

final class MenuDescriptorTests: XCTestCase {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // ── MenuItemDescriptor ────────────────────────────────────────────────

    func test_menuItem_defaults() {
        let item = MenuItemDescriptor(id: "x", label: "X")
        XCTAssertTrue(item.isEnabled)
        XCTAssertFalse(item.isChecked)
        XCTAssertFalse(item.isSeparator)
    }

    func test_separator_detection() {
        let sep = MenuItemDescriptor(type: .separator)
        XCTAssertTrue(sep.isSeparator)
    }

    func test_menuItem_roundtrip() throws {
        let original = MenuItemDescriptor(
            type: .item, id: "file.new", label: "New",
            key: "n", modifiers: [.cmd, .shift],
            enabled: false, checked: true
        )
        let decoded = try decoder.decode(MenuItemDescriptor.self,
                                         from: try encoder.encode(original))
        XCTAssertEqual(original, decoded)
    }

    func test_separator_roundtrip() throws {
        let sep     = MenuItemDescriptor(type: .separator)
        let decoded = try decoder.decode(MenuItemDescriptor.self,
                                         from: try encoder.encode(sep))
        XCTAssertEqual(sep, decoded)
    }

    // ── InboundMessage — existing types ──────────────────────────────────

    func test_setMenu_decode() throws {
        let json = """
        {"type":"set_menu","menus":[{"label":"File","items":[
          {"id":"file.new","label":"New","key":"n","modifiers":["cmd"]}
        ]}]}
        """.data(using: .utf8)!
        let msg = try decoder.decode(InboundMessage.self, from: json)
        guard case .setMenu(let menus) = msg else {
            return XCTFail("Expected .setMenu")
        }
        XCTAssertEqual(menus.count, 1)
        XCTAssertEqual(menus[0].items[0].id, "file.new")
    }

    func test_patchMenu_decode() throws {
        let json = """
        {"type":"patch_menu","patches":[
          {"id":"file.close","enabled":false}
        ]}
        """.data(using: .utf8)!
        let msg = try decoder.decode(InboundMessage.self, from: json)
        guard case .patchMenu(let patches) = msg else {
            return XCTFail("Expected .patchMenu")
        }
        XCTAssertEqual(patches[0].enabled, false)
    }

    // ── InboundMessage — new types ────────────────────────────────────────

    func test_setURL_decode() throws {
        let json = #"{"type":"set_url","url":"http://127.0.0.1:3000"}"#
            .data(using: .utf8)!
        let msg = try decoder.decode(InboundMessage.self, from: json)
        guard case .setURL(let url) = msg else {
            return XCTFail("Expected .setURL")
        }
        XCTAssertEqual(url, "http://127.0.0.1:3000")
    }

    func test_setURL_roundtrip() throws {
        let original = InboundMessage.setURL(url: "http://localhost:8080")
        let decoded  = try decoder.decode(InboundMessage.self,
                                          from: try encoder.encode(original))
        XCTAssertEqual(original, decoded)
    }

    func test_setScript_decode() throws {
        let json = #"{"type":"set_script","script":"console.log('hi')"}"#
            .data(using: .utf8)!
        let msg = try decoder.decode(InboundMessage.self, from: json)
        guard case .setScript(let script) = msg else {
            return XCTFail("Expected .setScript")
        }
        XCTAssertEqual(script, "console.log('hi')")
    }

    func test_setScript_roundtrip() throws {
        let original = InboundMessage.setScript(script: "(function(){})()")
        let decoded  = try decoder.decode(InboundMessage.self,
                                          from: try encoder.encode(original))
        XCTAssertEqual(original, decoded)
    }

    func test_setDevTools_enabled_decode() throws {
        let json = #"{"type":"set_devtools","enabled":true}"#.data(using: .utf8)!
        let msg  = try decoder.decode(InboundMessage.self, from: json)
        guard case .setDevTools(let enabled) = msg else {
            return XCTFail("Expected .setDevTools")
        }
        XCTAssertTrue(enabled)
    }

    func test_setDevTools_disabled_decode() throws {
        let json = #"{"type":"set_devtools","enabled":false}"#.data(using: .utf8)!
        let msg  = try decoder.decode(InboundMessage.self, from: json)
        guard case .setDevTools(let enabled) = msg else {
            return XCTFail("Expected .setDevTools")
        }
        XCTAssertFalse(enabled)
    }

    func test_setDevTools_roundtrip() throws {
        for value in [true, false] {
            let original = InboundMessage.setDevTools(enabled: value)
            let decoded  = try decoder.decode(InboundMessage.self,
                                              from: try encoder.encode(original))
            XCTAssertEqual(original, decoded)
        }
    }

    func test_unknownType_throws() {
        let json = #"{"type":"hover_item","id":"x"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(InboundMessage.self, from: json))
    }

    // ── OutboundMessage — existing types ──────────────────────────────────

    func test_menuAction_encode() throws {
        let data = try encoder.encode(OutboundMessage.menuAction(id: "file.new"))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "menu_action")
        XCTAssertEqual(json["id"]   as? String, "file.new")
    }

    func test_fileOpen_encode() throws {
        let paths = ["/Users/me/doc.myext"]
        let data  = try encoder.encode(OutboundMessage.fileOpen(paths: paths))
        let json  = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"]  as? String,   "file_open")
        XCTAssertEqual(json["paths"] as? [String], paths)
    }

    func test_appReopen_encode() throws {
        let data = try encoder.encode(OutboundMessage.appReopen)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "app_reopen")
    }

    // ── OutboundMessage — new windowClosed ────────────────────────────────

    func test_windowClosed_encode() throws {
        let data = try encoder.encode(OutboundMessage.windowClosed)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "window_closed")
    }

    func test_windowClosed_roundtrip() throws {
        let original = OutboundMessage.windowClosed
        let decoded  = try decoder.decode(OutboundMessage.self,
                                          from: try encoder.encode(original))
        XCTAssertEqual(original, decoded)
    }

    // ── Full outbound roundtrip ───────────────────────────────────────────

    func test_all_outbound_roundtrip() throws {
        let cases: [OutboundMessage] = [
            .menuAction(id: "view.zoom"),
            .fileOpen(paths: ["/tmp/a.txt"]),
            .appReopen,
            .windowClosed,
        ]
        for msg in cases {
            let decoded = try decoder.decode(OutboundMessage.self,
                                             from: try encoder.encode(msg))
            XCTAssertEqual(msg, decoded, "Round-trip failed for \(msg)")
        }
    }
}
