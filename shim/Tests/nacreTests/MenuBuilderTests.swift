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

    // ── buildMenuBar — edge cases ─────────────────────────────────────────

    func test_buildMenuBar_empty_descriptors_produces_empty_bar() {
        let bar = MenuBuilder.buildMenuBar(from: [], target: target)
        XCTAssertEqual(bar.items.count, 0)
    }

    func test_buildMenuBar_separators_survive_full_pipeline() {
        let bar = MenuBuilder.buildMenuBar(from: [
            MenuDescriptor(label: "File", items: [
                MenuItemDescriptor(id: "file.new",  label: "New"),
                MenuItemDescriptor(type: .separator),
                MenuItemDescriptor(id: "file.quit", label: "Quit"),
            ])
        ], target: target)

        let sub = bar.items[0].submenu!
        XCTAssertEqual(sub.items.count, 3)
        XCTAssertTrue(sub.items[1].isSeparatorItem, "Middle item must be a separator")
        XCTAssertFalse(sub.items[0].isSeparatorItem)
        XCTAssertFalse(sub.items[2].isSeparatorItem)
    }

    func test_buildMenuBar_nested_submenu_survives_full_pipeline() {
        let bar = MenuBuilder.buildMenuBar(from: [
            MenuDescriptor(label: "View", items: [
                MenuItemDescriptor(
                    id:      "view.zoom",
                    label:   "Zoom",
                    submenu: [
                        MenuItemDescriptor(id: "view.zoom.in",  label: "Zoom In"),
                        MenuItemDescriptor(id: "view.zoom.out", label: "Zoom Out"),
                    ]
                )
            ])
        ], target: target)

        let zoomItem = bar.items[0].submenu?.items[0]
        XCTAssertNotNil(zoomItem?.submenu)
        XCTAssertEqual(zoomItem?.submenu?.items.count, 2)
        XCTAssertEqual(zoomItem?.submenu?.items[0].title, "Zoom In")
        XCTAssertEqual(zoomItem?.submenu?.items[1].title, "Zoom Out")
    }

    func test_buildMenuBar_multiple_top_level_menus() {
        let bar = MenuBuilder.buildMenuBar(from: [
            MenuDescriptor(label: "File", items: [
                MenuItemDescriptor(id: "file.new", label: "New")
            ]),
            MenuDescriptor(label: "Edit", items: [
                MenuItemDescriptor(id: "edit.copy", label: "Copy")
            ]),
            MenuDescriptor(label: "View", items: [
                MenuItemDescriptor(id: "view.zoom", label: "Zoom")
            ]),
        ], target: target)

        XCTAssertEqual(bar.items.count, 3)
        XCTAssertEqual(bar.items[0].title, "File")
        XCTAssertEqual(bar.items[1].title, "Edit")
        XCTAssertEqual(bar.items[2].title, "View")
    }

    // ── applyPatches — depth-first search through submenus ────────────────

    func test_applyPatches_reaches_item_inside_submenu() {
        let bar = MenuBuilder.buildMenuBar(from: [
            MenuDescriptor(label: "View", items: [
                MenuItemDescriptor(
                    id:      "view.zoom",
                    label:   "Zoom",
                    submenu: [
                        MenuItemDescriptor(id: "view.zoom.in",  label: "Zoom In"),
                        MenuItemDescriptor(id: "view.zoom.out", label: "Zoom Out"),
                    ]
                )
            ])
        ], target: target)

        MenuBuilder.applyPatches(
            [MenuPatch(id: "view.zoom.in", label: "Zoom In ⌘+", enabled: false)],
            to: bar
        )

        let item = findItem(id: "view.zoom.in", in: bar)
        XCTAssertEqual(item?.title,     "Zoom In ⌘+")
        XCTAssertEqual(item?.isEnabled, false)
    }

    func test_applyPatches_reaches_items_across_multiple_top_level_menus() {
        let bar = MenuBuilder.buildMenuBar(from: [
            MenuDescriptor(label: "File", items: [
                MenuItemDescriptor(id: "file.new", label: "New")
            ]),
            MenuDescriptor(label: "Edit", items: [
                MenuItemDescriptor(id: "edit.copy", label: "Copy")
            ]),
        ], target: target)

        MenuBuilder.applyPatches([
            MenuPatch(id: "file.new",  label: "New Window"),
            MenuPatch(id: "edit.copy", enabled: false),
        ], to: bar)

        XCTAssertEqual(findItem(id: "file.new",  in: bar)?.title,     "New Window")
        XCTAssertEqual(findItem(id: "edit.copy", in: bar)?.isEnabled, false)
    }

    // ── validateDescriptors — submenu recursion ───────────────────────────

    func test_validate_catches_missing_id_inside_submenu() {
        let menus = [MenuDescriptor(label: "View", items: [
            MenuItemDescriptor(
                id:    "view.zoom",
                label: "Zoom",
                submenu: [
                    MenuItemDescriptor(id: nil, label: "Zoom In") // missing id
                ]
            )
        ])]
        let errors = MenuBuilder.validateDescriptors(menus)
        XCTAssertTrue(
            errors.contains(where: { $0.contains("missing 'id'") }),
            "Should report missing id inside submenu. Got: \(errors)"
        )
    }

    func test_validate_catches_duplicate_id_across_menus() {
        // Same ID used in File and Edit — must be caught
        let menus = [
            MenuDescriptor(label: "File", items: [
                MenuItemDescriptor(id: "shared.id", label: "Item A")
            ]),
            MenuDescriptor(label: "Edit", items: [
                MenuItemDescriptor(id: "shared.id", label: "Item B")
            ]),
        ]
        let errors = MenuBuilder.validateDescriptors(menus)
        XCTAssertTrue(
            errors.contains(where: { $0.contains("duplicate id") && $0.contains("shared.id") }),
            "Should report cross-menu duplicate ID. Got: \(errors)"
        )
    }

    func test_validate_catches_duplicate_id_in_submenu_vs_parent() {
        let menus = [MenuDescriptor(label: "File", items: [
            MenuItemDescriptor(
                id:    "dup",
                label: "Parent",
                submenu: [
                    MenuItemDescriptor(id: "dup", label: "Child") // same as parent
                ]
            )
        ])]
        let errors = MenuBuilder.validateDescriptors(menus)
        XCTAssertTrue(
            errors.contains(where: { $0.contains("duplicate id") }),
            "Should report duplicate id between parent and submenu child. Got: \(errors)"
        )
    }

    // ── MenuActionReceiver — selector wiring ──────────────────────────────

    func test_menuItemActivated_delivers_representedObject_id() {
        let bar  = buildTestBar()
        let item = findItem(id: "file.new", in: bar)!

        // Simulate the action — directly invoke the selector on the target
        target.menuItemActivated(item)

        XCTAssertEqual(target.activatedIDs, ["file.new"])
    }

    func test_menuItemActivated_delivers_correct_id_for_multiple_items() {
        let bar = buildTestBar()

        target.menuItemActivated(findItem(id: "file.new",  in: bar)!)
        target.menuItemActivated(findItem(id: "file.open", in: bar)!)
        target.menuItemActivated(findItem(id: "file.new",  in: bar)!)

        XCTAssertEqual(target.activatedIDs, ["file.new", "file.open", "file.new"])
    }

    func test_menuItemActivated_ignores_item_without_representedObject() {
        // Separators and items built without an id have no representedObject
        let separator = NSMenuItem.separator()
        target.menuItemActivated(separator)
        XCTAssertTrue(target.activatedIDs.isEmpty,
                      "Separator should produce no activation")
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
