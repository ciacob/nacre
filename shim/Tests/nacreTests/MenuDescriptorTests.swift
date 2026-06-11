// MenuDescriptorTests.swift
// nacreTests
//
// Tests for MenuDescriptor, InboundMessage, OutboundMessage Codable
// round-trips and edge cases.  No AppKit required.

import XCTest
@testable import nacreLib

final class MenuDescriptorTests: XCTestCase {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // ── MenuItemDescriptor ────────────────────────────────────────────────

    func test_menuItem_defaults() {
        let item = MenuItemDescriptor(id: "x", label: "X")
        XCTAssertTrue(item.isEnabled,   "enabled should default to true")
        XCTAssertFalse(item.isChecked,  "checked should default to false")
        XCTAssertFalse(item.isSeparator,"type defaults to .item, not separator")
    }

    func test_separator_detection() {
        let sep = MenuItemDescriptor(type: .separator)
        XCTAssertTrue(sep.isSeparator)
        XCTAssertFalse(sep.isEnabled == false, "isSeparator doesn't affect isEnabled")
    }

    func test_menuItem_roundtrip() throws {
        let original = MenuItemDescriptor(
            type:      .item,
            id:        "file.new",
            label:     "New",
            key:       "n",
            modifiers: [.cmd, .shift],
            enabled:   false,
            checked:   true
        )
        let data    = try encoder.encode(original)
        let decoded = try decoder.decode(MenuItemDescriptor.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func test_separator_roundtrip() throws {
        let sep     = MenuItemDescriptor(type: .separator)
        let data    = try encoder.encode(sep)
        let decoded = try decoder.decode(MenuItemDescriptor.self, from: data)
        XCTAssertEqual(sep, decoded)
    }

    // ── InboundMessage ────────────────────────────────────────────────────

    func test_setMenu_decode() throws {
        let json = """
        {
          "type": "set_menu",
          "menus": [
            {
              "label": "File",
              "items": [
                { "id": "file.new", "label": "New", "key": "n", "modifiers": ["cmd"] }
              ]
            }
          ]
        }
        """.data(using: .utf8)!

        let msg = try decoder.decode(InboundMessage.self, from: json)
        guard case .setMenu(let menus) = msg else {
            return XCTFail("Expected .setMenu, got \(msg)")
        }
        XCTAssertEqual(menus.count, 1)
        XCTAssertEqual(menus[0].label, "File")
        XCTAssertEqual(menus[0].items[0].id, "file.new")
        XCTAssertEqual(menus[0].items[0].modifiers, [.cmd])
    }

    func test_patchMenu_decode() throws {
        let json = """
        {
          "type": "patch_menu",
          "patches": [
            { "id": "file.close", "enabled": false },
            { "id": "file.save",  "label": "Save…", "checked": true }
          ]
        }
        """.data(using: .utf8)!

        let msg = try decoder.decode(InboundMessage.self, from: json)
        guard case .patchMenu(let patches) = msg else {
            return XCTFail("Expected .patchMenu, got \(msg)")
        }
        XCTAssertEqual(patches.count, 2)
        XCTAssertEqual(patches[0].id, "file.close")
        XCTAssertEqual(patches[0].enabled, false)
        XCTAssertEqual(patches[1].label, "Save…")
        XCTAssertEqual(patches[1].checked, true)
    }

    func test_unknownType_throws() {
        let json = #"{"type":"hover_item","id":"x"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try decoder.decode(InboundMessage.self, from: json))
    }

    func test_setMenu_roundtrip() throws {
        let original = InboundMessage.setMenu(menus: [
            MenuDescriptor(label: "Edit", items: [
                MenuItemDescriptor(id: "edit.copy", label: "Copy", key: "c", modifiers: [.cmd])
            ])
        ])
        let data    = try encoder.encode(original)
        let decoded = try decoder.decode(InboundMessage.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    // ── OutboundMessage ───────────────────────────────────────────────────

    func test_menuAction_encode() throws {
        let msg  = OutboundMessage.menuAction(id: "file.new")
        let data = try encoder.encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "menu_action")
        XCTAssertEqual(json["id"]   as? String, "file.new")
    }

    func test_fileOpen_encode() throws {
        let paths = ["/Users/me/doc.myext", "/Users/me/other.myext"]
        let msg   = OutboundMessage.fileOpen(paths: paths)
        let data  = try encoder.encode(msg)
        let json  = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"]  as? String,   "file_open")
        XCTAssertEqual(json["paths"] as? [String], paths)
    }

    func test_appReopen_encode() throws {
        let msg  = OutboundMessage.appReopen
        let data = try encoder.encode(msg)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["type"] as? String, "app_reopen")
    }

    func test_outbound_roundtrip() throws {
        let cases: [OutboundMessage] = [
            .menuAction(id: "view.zoom"),
            .fileOpen(paths: ["/tmp/a.txt", "/tmp/b.txt"]),
            .appReopen
        ]
        for msg in cases {
            let data    = try encoder.encode(msg)
            let decoded = try decoder.decode(OutboundMessage.self, from: data)
            XCTAssertEqual(msg, decoded, "Round-trip failed for \(msg)")
        }
    }
}
