// MenuDescriptor.swift
// nacreLib
//
// Plain-data model for the JSON menu/control protocol.
// No Cocoa imports — these types are safe to use in tests on Linux too.
//
// ── Inbound wire format examples (Node.js → nacre) ───────────────────────────
//
//  Set the menu bar:
//  { "type": "set_menu", "menus": [{ "label": "File", "items": [...] }] }
//
//  Patch specific items by id:
//  { "type": "patch_menu", "patches": [{ "id": "file.save", "enabled": true }] }
//
//  Load a URL in the web view:
//  { "type": "set_url", "url": "http://127.0.0.1:3000" }
//
//  Inject a JS guard script (runs before page code on every navigation):
//  { "type": "set_script", "script": "(function(){ ... })()" }
//
//  Toggle developer tools:
//  { "type": "set_devtools", "enabled": true }
//
// ── Outbound wire format examples (nacre → Node.js) ──────────────────────────
//
//  User activated a menu item:
//  { "type": "menu_action", "id": "file.new" }
//
//  macOS delivered a file-open request:
//  { "type": "file_open", "paths": ["/Users/me/doc.myext"] }
//
//  User clicked Dock icon while app is already running:
//  { "type": "app_reopen" }
//
//  User closed the app window (red button):
//  { "type": "window_closed" }

import Foundation

// ── Key modifier names ────────────────────────────────────────────────────────

public enum MenuModifier: String, Codable, Equatable {
    case cmd     = "cmd"
    case shift   = "shift"
    case option  = "option"
    case control = "control"
}

// ── A single menu item ────────────────────────────────────────────────────────

public struct MenuItemDescriptor: Codable, Equatable {

    public var type:     ItemType?
    public var id:       String?
    public var label:    String?
    public var key:      String?
    public var modifiers:[MenuModifier]?
    public var enabled:  Bool?
    public var checked:  Bool?
    public var submenu:  [MenuItemDescriptor]?

    public enum ItemType: String, Codable {
        case item      = "item"
        case separator = "separator"
    }

    public var isSeparator: Bool { type == .separator }
    public var isEnabled:   Bool { enabled ?? true }
    public var isChecked:   Bool { checked ?? false }

    public init(
        type:      ItemType?             = .item,
        id:        String?               = nil,
        label:     String?               = nil,
        key:       String?               = nil,
        modifiers: [MenuModifier]?       = nil,
        enabled:   Bool?                 = nil,
        checked:   Bool?                 = nil,
        submenu:   [MenuItemDescriptor]? = nil
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

// ── A top-level menu ──────────────────────────────────────────────────────────

public struct MenuDescriptor: Codable, Equatable {
    public var label: String
    public var items: [MenuItemDescriptor]

    public init(label: String, items: [MenuItemDescriptor]) {
        self.label = label
        self.items = items
    }
}

// ── A single patch operation ──────────────────────────────────────────────────

public struct MenuPatch: Codable, Equatable {
    public var id:      String
    public var label:   String?
    public var enabled: Bool?
    public var checked: Bool?

    public init(id: String, label: String? = nil,
                enabled: Bool? = nil, checked: Bool? = nil) {
        self.id      = id
        self.label   = label
        self.enabled = enabled
        self.checked = checked
    }
}

// ── Inbound messages (Node.js → nacre) ───────────────────────────────────────

public enum InboundMessage: Codable, Equatable {

    case setMenu(menus: [MenuDescriptor])
    case patchMenu(patches: [MenuPatch])
    case setURL(url: String)
    case setScript(script: String)
    case setDevTools(enabled: Bool)

    private enum CodingKeys: String, CodingKey {
        case type, menus, patches, url, script, enabled
    }

    public init(from decoder: Decoder) throws {
        let c    = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .type)
        switch kind {
        case "set_menu":
            self = .setMenu(menus: try c.decode([MenuDescriptor].self, forKey: .menus))
        case "patch_menu":
            self = .patchMenu(patches: try c.decode([MenuPatch].self, forKey: .patches))
        case "set_url":
            self = .setURL(url: try c.decode(String.self, forKey: .url))
        case "set_script":
            self = .setScript(script: try c.decode(String.self, forKey: .script))
        case "set_devtools":
            self = .setDevTools(enabled: try c.decode(Bool.self, forKey: .enabled))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "Unknown inbound message type: \(kind)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .setMenu(let menus):
            try c.encode("set_menu",  forKey: .type)
            try c.encode(menus,       forKey: .menus)
        case .patchMenu(let patches):
            try c.encode("patch_menu", forKey: .type)
            try c.encode(patches,      forKey: .patches)
        case .setURL(let url):
            try c.encode("set_url", forKey: .type)
            try c.encode(url,       forKey: .url)
        case .setScript(let script):
            try c.encode("set_script", forKey: .type)
            try c.encode(script,       forKey: .script)
        case .setDevTools(let enabled):
            try c.encode("set_devtools", forKey: .type)
            try c.encode(enabled,        forKey: .enabled)
        }
    }
}

// ── Outbound messages (nacre → Node.js) ──────────────────────────────────────

public enum OutboundMessage: Codable, Equatable {

    case menuAction(id: String)
    case fileOpen(paths: [String])
    case appReopen
    case windowClosed

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
        case .windowClosed:
            try c.encode("window_closed", forKey: .type)
        }
    }

    public init(from decoder: Decoder) throws {
        let c    = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .type)
        switch kind {
        case "menu_action":
            self = .menuAction(id: try c.decode(String.self, forKey: .id))
        case "file_open":
            self = .fileOpen(paths: try c.decode([String].self, forKey: .paths))
        case "app_reopen":
            self = .appReopen
        case "window_closed":
            self = .windowClosed
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type, in: c,
                debugDescription: "Unknown outbound message type: \(kind)"
            )
        }
    }
}
