// MenuBuilder.swift
// nacreLib
//
// Converts MenuDescriptor trees into NSMenu / NSMenuItem object graphs.
//
// Design constraints
// ──────────────────
// • All public entry points are static functions — no stored state, no singletons.
// • The only side-effect is constructing AppKit objects; no I/O, no globals.
// • The `target` / `action` wiring is injected by the caller so this file
//   has no knowledge of AppDelegate or any other concrete responder.
//
// Testability note
// ─────────────────
// Because AppKit is only available on macOS, tests that import nacreLib on
// macOS can exercise MenuBuilder directly.  The pure-data validation helpers
// (validateDescriptor, etc.) are also callable from any platform.

import AppKit
import Foundation

public enum MenuBuilder {

    // ── Public API ────────────────────────────────────────────────────────

    /// Build a complete NSMenu bar from an ordered array of MenuDescriptors.
    ///
    /// - Parameters:
    ///   - descriptors: Top-level menus (File, Edit, View, …)
    ///   - target:      The object that will receive `menuItemActivated(_:)`
    ///                  selector calls.  Typically AppDelegate.
    /// - Returns: A fully populated NSMenu suitable for
    ///            `NSApplication.shared.mainMenu = …`
    public static func buildMenuBar(
        from descriptors: [MenuDescriptor],
        target: AnyObject
    ) -> NSMenu {
        let bar = NSMenu(title: "MainMenu")
        for desc in descriptors {
            let topItem = NSMenuItem(title: desc.label, action: nil, keyEquivalent: "")
            let sub     = buildMenu(from: desc, target: target)
            topItem.submenu = sub
            bar.addItem(topItem)
        }
        return bar
    }

    /// Build a single NSMenu from one MenuDescriptor (the menu's items).
    public static func buildMenu(
        from descriptor: MenuDescriptor,
        target: AnyObject
    ) -> NSMenu {
        let menu = NSMenu(title: descriptor.label)
        menu.autoenablesItems = false   // we manage enabled state manually
        for itemDesc in descriptor.items {
            menu.addItem(buildItem(from: itemDesc, target: target))
        }
        return menu
    }

    /// Build a single NSMenuItem from a MenuItemDescriptor.
    public static func buildItem(
        from descriptor: MenuItemDescriptor,
        target: AnyObject
    ) -> NSMenuItem {
        if descriptor.isSeparator {
            return .separator()
        }

        let key  = descriptor.key ?? ""
        let item = NSMenuItem(
            title:          descriptor.label ?? "",
            action:         #selector(MenuActionReceiver.menuItemActivated(_:)),
            keyEquivalent:  key
        )
        item.target             = target
        item.isEnabled          = descriptor.isEnabled
        item.state              = descriptor.isChecked ? .on : .off
        item.keyEquivalentModifierMask = modifierMask(from: descriptor.modifiers ?? [])

        // Tag the item with its stable ID so the action handler can look it up.
        // We store the ID in representedObject (typed, no hash collisions).
        if let id = descriptor.id {
            item.representedObject = id
        }

        // Recurse for submenus
        if let subItems = descriptor.submenu, !subItems.isEmpty {
            let subDesc = MenuDescriptor(label: descriptor.label ?? "", items: subItems)
            item.submenu = buildMenu(from: subDesc, target: target)
            item.action  = nil   // items with submenus don't fire actions
        }

        return item
    }

    /// Apply a batch of MenuPatch objects to an existing NSMenu bar in-place.
    ///
    /// - Parameters:
    ///   - patches:  Array of patch descriptors.
    ///   - menuBar:  The NSMenu returned by a previous `buildMenuBar` call.
    /// - Returns:    IDs that were referenced in patches but not found in the
    ///               menu tree (useful for diagnostics / logging).
    @discardableResult
    public static func applyPatches(
        _ patches: [MenuPatch],
        to menuBar: NSMenu
    ) -> [String] {
        var missing: [String] = []
        for patch in patches {
            if let item = findItem(id: patch.id, in: menuBar) {
                if let label   = patch.label   { item.title    = label }
                if let enabled = patch.enabled { item.isEnabled = enabled }
                if let checked = patch.checked { item.state    = checked ? .on : .off }
            } else {
                missing.append(patch.id)
            }
        }
        return missing
    }

    // ── Pure validation helpers (platform-independent) ────────────────────

    /// Returns a list of human-readable validation errors for a descriptor
    /// tree, or an empty array if the descriptor is well-formed.
    ///
    /// Rules:
    ///   • Non-separator items must have a non-empty `id`.
    ///   • Non-separator items must have a non-empty `label`.
    ///   • `key` must be a single character if present.
    ///   • IDs must be unique within the entire tree.
    public static func validateDescriptors(_ menus: [MenuDescriptor]) -> [String] {
        var errors: [String]   = []
        var seenIDs: Set<String> = []

        func validateItem(_ item: MenuItemDescriptor, path: String) {
            guard !item.isSeparator else { return }

            let itemPath = path + "/\(item.id ?? "<no-id>")"

            if (item.id ?? "").isEmpty {
                errors.append("\(itemPath): non-separator item is missing 'id'")
            }
            if (item.label ?? "").isEmpty {
                errors.append("\(itemPath): non-separator item is missing 'label'")
            }
            if let key = item.key, key.count != 1 {
                errors.append("\(itemPath): 'key' must be a single character, got '\(key)'")
            }
            if let id = item.id {
                if seenIDs.contains(id) {
                    errors.append("\(itemPath): duplicate id '\(id)'")
                } else {
                    seenIDs.insert(id)
                }
            }
            for sub in item.submenu ?? [] {
                validateItem(sub, path: itemPath)
            }
        }

        for menu in menus {
            let menuPath = "/\(menu.label)"
            for item in menu.items {
                validateItem(item, path: menuPath)
            }
        }
        return errors
    }

    // ── Private helpers ───────────────────────────────────────────────────

    /// Depth-first search for an NSMenuItem whose representedObject matches `id`.
    private static func findItem(id: String, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if let itemID = item.representedObject as? String, itemID == id {
                return item
            }
            if let sub = item.submenu, let found = findItem(id: id, in: sub) {
                return found
            }
        }
        return nil
    }

    /// Convert an array of MenuModifier values to NSEvent.ModifierFlags.
    static func modifierMask(from modifiers: [MenuModifier]) -> NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        for mod in modifiers {
            switch mod {
            case .cmd:     mask.insert(.command)
            case .shift:   mask.insert(.shift)
            case .option:  mask.insert(.option)
            case .control: mask.insert(.control)
            }
        }
        // Default to .command when no modifiers specified and a key is present,
        // matching macOS convention.  Callers that pass an empty array get an
        // empty mask (e.g. function keys).
        return mask
    }
}

// ── Selector protocol ─────────────────────────────────────────────────────────
// Defines the selector that NSMenuItems target, without importing AppDelegate.
// AppDelegate conforms to this protocol.

@objc public protocol MenuActionReceiver: AnyObject {
    /// Called when a menu item with a stable `id` (stored in `representedObject`)
    /// is activated by the user.
    @objc func menuItemActivated(_ sender: NSMenuItem)
}
