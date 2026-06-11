// MenuDescriptor.swift
// nacreLib
//
// Plain-data model for the JSON menu protocol.
// No Cocoa imports — these types are safe to use in tests on Linux too.
//
// Wire format example (inbound from Node.js):
//
//   {
//     "type": "set_menu",
//     "menus": [
//       {
//         "label": "File",
//         "items": [
//           { "id": "file.new",  "label": "New",  "key": "n", "modifiers": ["cmd"] },
//           { "id": "file.open", "label": "Open…","key": "o", "modifiers": ["cmd"] },
//           { "type": "separator" },
//           { "id": "file.close","label": "Close","key": "w", "modifiers": ["cmd"],
//             "enabled": false }
//         ]
//       }
//     ]
//   }

import Foundation

// ── Key modifier names (subset of NSEventModifierFlags, by string name) ──────

public enum MenuModifier: String, Codable, Equatable {
    case cmd     = "cmd"
    case shift   = "shift"
    case option  = "option"
    case control = "control"
}

// ── A single menu item ────────────────────────────────────────────────────────

public struct MenuItemDescriptor: Codable, Equatable {

    // "item" (default) or "separator"
    public var type: ItemType?

    // Stable identifier used for patch_menu and menu_action events.
    // Required for type == "item", absent for separators.
    public var id: String?

    public var label: String?

    // Single-character keyboard equivalent (e.g. "n", "o", "w")
    public var key: String?

    public var modifiers: [MenuModifier]?

    // Defaults to true when absent
    public var enabled: Bool?

    // Checkmark state
    public var checked: Bool?

    // Nested submenu items
    public var submenu: [MenuItemDescriptor]?

    public enum ItemType: String, Codable {
        case item      = "item"
        case separator = "separator"
    }

    // Convenience: is this a separator?
    public var isSeparator: Bool {
        type == .separator
    }

    // Convenience: effective enabled state (nil → true)
    public var isEnabled: Bool {
        enabled ?? true
    }

    // Convenience: effective checked state (nil → false)
    public var isChecked: Bool {
        checked ?? false
    }

    public init(
        type: ItemType? = .item,
        id: String? = nil,
        label: String? = nil,
        key: String? = nil,
        modifiers: [MenuModifier]? = nil,
        enabled: Bool? = nil,
        checked: Bool? = nil,
        submenu: [MenuItemDescriptor]? = nil
    ) {
        self.type      = type
        self.id        = id
        self.label     = label
        self.key       = key
        self.modifiers = modifiers
        self.enabled   = enabled
        self.checked   = checked
        self.submenu   = submenu
    }
}

// ── A top-level menu (e.g. "File", "Edit", "View") ───────────────────────────

public struct MenuDescriptor: Codable, Equatable {
    public var label: String
    public var items: [MenuItemDescriptor]

    public init(label: String, items: [MenuItemDescriptor]) {
        self.label = label
        self.items = items
    }
}

// ── Inbound socket messages (Node.js → shim) ──────────────────────────────────

public enum InboundMessage: Codable, Equatable {

    case setMenu(menus: [MenuDescriptor])
    case patchMenu(patches: [MenuPatch])

    // Manual Codable because the discriminant is a sibling "type" field,
    // not a wrapped enum key.
    private enum CodingKeys: String, CodingKey {
        case type, menus, patches
    }

    public init(from decoder: Decoder) throws {
        let c    = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .type)
        switch kind {
        case "set_menu":
            let menus = try c.decode([MenuDescriptor].self, forKey: .menus)
            self = .setMenu(menus: menus)
        case "patch_menu":
            let patches = try c.decode([MenuPatch].self, forKey: .patches)
            self = .patchMenu(patches: patches)
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: c,
                debugDescription: "Unknown inbound message type: \(kind)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .setMenu(let menus):
            try c.encode("set_menu", forKey: .type)
            try c.encode(menus, forKey: .menus)
        case .patchMenu(let patches):
            try c.encode("patch_menu", forKey: .type)
            try c.encode(patches, forKey: .patches)
        }
    }
}

// ── A single patch operation (for patch_menu) ─────────────────────────────────

public struct MenuPatch: Codable, Equatable {
    public var id:      String
    public var label:   String?
    public var enabled: Bool?
    public var checked: Bool?

    public init(id: String, label: String? = nil, enabled: Bool? = nil, checked: Bool? = nil) {
        self.id      = id
        self.label   = label
        self.enabled = enabled
        self.checked = checked
    }
}

// ── Outbound socket messages (shim → Node.js) ─────────────────────────────────

public enum OutboundMessage: Codable, Equatable {

    // User activated a menu item
    case menuAction(id: String)

    // macOS delivered file-open request (Finder, drag-to-dock, registered UTI)
    case fileOpen(paths: [String])

    // User clicked Dock icon while app is already running
    case appReopen

    private enum CodingKeys: String, CodingKey {
        case type, id, paths
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .menuAction(let id):
            try c.encode("menu_action", forKey: .type)
            try c.encode(id,            forKey: .id)
        case .fileOpen(let paths):
            try c.encode("file_open", forKey: .type)
            try c.encode(paths,       forKey: .paths)
        case .appReopen:
            try c.encode("app_reopen", forKey: .type)
        }
    }

    public init(from decoder: Decoder) throws {
        let c    = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .type)
        switch kind {
        case "menu_action":
            let id = try c.decode(String.self, forKey: .id)
            self = .menuAction(id: id)
        case "file_open":
            let paths = try c.decode([String].self, forKey: .paths)
            self = .fileOpen(paths: paths)
        case "app_reopen":
            self = .appReopen
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: c,
                debugDescription: "Unknown outbound message type: \(kind)"
            )
        }
    }
}
