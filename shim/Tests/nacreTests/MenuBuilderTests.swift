// MenuBuilderTests.swift
// nacreTests
//
// Tests for MenuBuilder: descriptor validation (platform-independent)
// and NSMenu construction (macOS only, but we're always on macOS here).

import XCTest
import AppKit
@testable import nacreLib

// ── Minimal MenuActionReceiver stub for tests ─────────────────────────────────

final class StubTarget: NSObject, MenuActionReceiver {
    var activatedIDs: [String] = []
    @objc func menuItemActivated(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String {
            activatedIDs.append(id)
        }
    }
}

// ── MenuBuilderTests ──────────────────────────────────────────────────────────

final class MenuBuilderTests: XCTestCase {

    private let target = StubTarget()

    // ── validateDescriptors ───────────────────────────────────────────────

    func test_validate_clean_descriptor_returns_no_errors() {
        let menus = [
            MenuDescriptor(label: "File", items: [
                MenuItemDescriptor(id: "file.new",  label: "New",   key: "n", modifiers: [.cmd]),
                MenuItemDescriptor(id: "file.open", label: "Open…", key: "o", modifiers: [.cmd]),
                MenuItemDescriptor(type: .separator),
                MenuItemDescriptor(id: "file.quit", label: "Quit",  key: "q", modifiers: [.cmd]),
            ])
        ]
        let errors = MenuBuilder.validateDescriptors(menus)
        XCTAssertTrue(errors.isEmpty, "Unexpected errors: \(errors)")
    }

    func test_validate_missing_id_is_reported() {
        let menus = [MenuDescriptor(label: "File", items: [
            MenuItemDescriptor(id: nil, label: "New")
        ])]
        let errors = MenuBuilder.validateDescriptors(menus)
        XCTAssertTrue(errors.contains(where: { $0.contains("missing 'id'") }),
                      "Expected missing-id error, got: \(errors)")
    }

    func test_validate_missing_label_is_reported() {
        let menus = [MenuDescriptor(label: "File", items: [
            MenuItemDescriptor(id: "file.new", label: nil)
        ])]
        let errors = MenuBuilder.validateDescriptors(menus)
        XCTAssertTrue(errors.contains(where: { $0.contains("missing 'label'") }),
                      "Expected missing-label error, got: \(errors)")
    }

    func test_validate_multichar_key_is_reported() {
        let menus = [MenuDescriptor(label: "File", items: [
            MenuItemDescriptor(id: "file.new", label: "New", key: "cmd")
        ])]
        let errors = MenuBuilder.validateDescriptors(menus)
        XCTAssertTrue(errors.contains(where: { $0.contains("single character") }),
                      "Expected single-character error, got: \(errors)")
    }

    func test_validate_duplicate_id_is_reported() {
        let menus = [MenuDescriptor(label: "File", items: [
            MenuItemDescriptor(id: "dup", label: "A"),
            MenuItemDescriptor(id: "dup", label: "B"),
        ])]
        let errors = MenuBuilder.validateDescriptors(menus)
        XCTAssertTrue(errors.contains(where: { $0.contains("duplicate id") }),
                      "Expected duplicate-id error, got: \(errors)")
    }

    func test_validate_separator_needs_no_id_or_label() {
        let menus = [MenuDescriptor(label: "File", items: [
            MenuItemDescriptor(type: .separator)
        ])]
        let errors = MenuBuilder.validateDescriptors(menus)
        XCTAssertTrue(errors.isEmpty, "Separator should not require id/label. Got: \(errors)")
    }

    // ── buildItem ─────────────────────────────────────────────────────────

    func test_buildItem_separator() {
        let item = MenuBuilder.buildItem(
            from: MenuItemDescriptor(type: .separator),
            target: target
        )
        XCTAssertTrue(item.isSeparatorItem)
    }

    func test_buildItem_basic_properties() {
        let desc = MenuItemDescriptor(
            id:        "file.new",
            label:     "New File",
            key:       "n",
            modifiers: [.cmd, .shift],
            enabled:   true,
            checked:   false
        )
        let item = MenuBuilder.buildItem(from: desc, target: target)
        XCTAssertEqual(item.title,              "New File")
        XCTAssertEqual(item.keyEquivalent,      "n")
        XCTAssertEqual(item.representedObject as? String, "file.new")
        XCTAssertTrue(item.isEnabled)
        XCTAssertEqual(item.state, .off)
        XCTAssertTrue(item.keyEquivalentModifierMask.contains(.command))
        XCTAssertTrue(item.keyEquivalentModifierMask.contains(.shift))
    }

    func test_buildItem_disabled_and_checked() {
        let desc = MenuItemDescriptor(
            id: "view.zoom", label: "Zoom", enabled: false, checked: true
        )
        let item = MenuBuilder.buildItem(from: desc, target: target)
        XCTAssertFalse(item.isEnabled)
        XCTAssertEqual(item.state, .on)
    }

    func test_buildItem_with_submenu() {
        let desc = MenuItemDescriptor(
            id:    "view",
            label: "View",
            submenu: [
                MenuItemDescriptor(id: "view.zoom",     label: "Zoom"),
                MenuItemDescriptor(id: "view.fullscreen",label: "Full Screen"),
            ]
        )
        let item = MenuBuilder.buildItem(from: desc, target: target)
        XCTAssertNotNil(item.submenu)
        XCTAssertEqual(item.submenu?.items.count, 2)
        XCTAssertNil(item.action, "Items with submenus must not have an action")
    }

    // ── buildMenuBar ──────────────────────────────────────────────────────

    func test_buildMenuBar_structure() {
        let descriptors = [
            MenuDescriptor(label: "File", items: [
                MenuItemDescriptor(id: "file.new",  label: "New"),
                MenuItemDescriptor(id: "file.open", label: "Open"),
            ]),
            MenuDescriptor(label: "Edit", items: [
                MenuItemDescriptor(id: "edit.copy",  label: "Copy"),
                MenuItemDescriptor(id: "edit.paste", label: "Paste"),
            ])
        ]
        let bar = MenuBuilder.buildMenuBar(from: descriptors, target: target)
        XCTAssertEqual(bar.items.count, 2)
        XCTAssertEqual(bar.items[0].title, "File")
        XCTAssertEqual(bar.items[1].title, "Edit")
        XCTAssertEqual(bar.items[0].submenu?.items.count, 2)
    }

    // ── applyPatches ──────────────────────────────────────────────────────

    func test_applyPatches_label() {
        let bar = buildTestBar()
        MenuBuilder.applyPatches(
            [MenuPatch(id: "file.new", label: "New Window")],
            to: bar
        )
        let item = findItem(id: "file.new", in: bar)
        XCTAssertEqual(item?.title, "New Window")
    }

    func test_applyPatches_enabled() {
        let bar = buildTestBar()
        MenuBuilder.applyPatches(
            [MenuPatch(id: "file.open", enabled: false)],
            to: bar
        )
        let item = findItem(id: "file.open", in: bar)
        XCTAssertEqual(item?.isEnabled, false)
    }

    func test_applyPatches_checked() {
        let bar = buildTestBar()
        MenuBuilder.applyPatches(
            [MenuPatch(id: "file.open", checked: true)],
            to: bar
        )
        let item = findItem(id: "file.open", in: bar)
        XCTAssertEqual(item?.state, .on)
    }

    func test_applyPatches_returns_missing_ids() {
        let bar     = buildTestBar()
        let missing = MenuBuilder.applyPatches(
            [MenuPatch(id: "does.not.exist", enabled: false)],
            to: bar
        )
        XCTAssertEqual(missing, ["does.not.exist"])
    }

    func test_applyPatches_multiple_in_one_call() {
        let bar = buildTestBar()
        MenuBuilder.applyPatches([
            MenuPatch(id: "file.new",  label: "New…",  enabled: false),
            MenuPatch(id: "file.open", label: "Open…", checked: true),
        ], to: bar)
        XCTAssertEqual(findItem(id: "file.new",  in: bar)?.title,     "New…")
        XCTAssertEqual(findItem(id: "file.new",  in: bar)?.isEnabled, false)
        XCTAssertEqual(findItem(id: "file.open", in: bar)?.title,     "Open…")
        XCTAssertEqual(findItem(id: "file.open", in: bar)?.state,     .on)
    }

    // ── modifierMask ──────────────────────────────────────────────────────

    func test_modifierMask_cmd() {
        let mask = MenuBuilder.modifierMask(from: [.cmd])
        XCTAssertTrue(mask.contains(.command))
        XCTAssertFalse(mask.contains(.shift))
    }

    func test_modifierMask_all() {
        let mask = MenuBuilder.modifierMask(from: [.cmd, .shift, .option, .control])
        XCTAssertTrue(mask.contains(.command))
        XCTAssertTrue(mask.contains(.shift))
        XCTAssertTrue(mask.contains(.option))
        XCTAssertTrue(mask.contains(.control))
    }

    func test_modifierMask_empty() {
        let mask = MenuBuilder.modifierMask(from: [])
        XCTAssertEqual(mask, [])
    }

    // ── Helpers ───────────────────────────────────────────────────────────

    private func buildTestBar() -> NSMenu {
        MenuBuilder.buildMenuBar(from: [
            MenuDescriptor(label: "File", items: [
                MenuItemDescriptor(id: "file.new",  label: "New"),
                MenuItemDescriptor(id: "file.open", label: "Open"),
            ])
        ], target: target)
    }

    private func findItem(id: String, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if let itemID = item.representedObject as? String, itemID == id { return item }
            if let sub = item.submenu, let found = findItem(id: id, in: sub) { return found }
        }
        return nil
    }
}
