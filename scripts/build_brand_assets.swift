#!/usr/bin/env swift  // Generate every logo asset from design/brand/mark.svg and brand.json.
import AppKit
import Foundation

struct Brand: Decodable {
    struct Appearance: Decodable {
        let background: String
        let backgroundEnd: String
    }
    struct Colors: Decodable {
        let light: Appearance
        let dark: Appearance
    }
    let name: String
    let iconViewBox: String
    let homeCornerRadius: Double
    let ink: String
    let colors: Colors
}

func failure(_ message: String) -> NSError {
    NSError(domain: "BrandAssets", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}

func channels(_ hex: String) throws -> [Double] {
    guard hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else {
        throw failure("Expected an opaque sRGB color in #RRGGBB form: \(hex)")
    }
    return [16, 8, 0].map { Double((value >> $0) & 255) / 255 }
}

func iconColor(_ color: String) throws -> String {
    let rgb = try channels(color)
    return String(
        format: "srgb:%.5f,%.5f,%.5f,1.00000", locale: Locale(identifier: "en_US_POSIX"),
        rgb[0], rgb[1], rgb[2])
}

func iconBackground(_ appearance: Brand.Appearance) throws -> [String: Any] {
    [
        "linear-gradient": [try iconColor(appearance.background), try iconColor(appearance.backgroundEnd)],
        "orientation": ["start": ["x": 0.5, "y": 0], "stop": ["x": 0.5, "y": 1]],
    ]
}

func json(_ value: Any) throws -> Data {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        + Data("\n".utf8)
}

func attribute(_ element: XMLElement, _ name: String, _ value: String) {
    if let existing = element.attribute(forName: name) {
        existing.stringValue = value
    } else {
        element.addAttribute(XMLNode.attribute(withName: name, stringValue: value) as! XMLNode)
    }
}

func viewBox(_ value: String) throws -> [String] {
    let parts = value.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    let numbers = parts.compactMap(Double.init)
    guard parts.count == 4, numbers.count == 4, numbers.allSatisfy(\.isFinite), numbers[2] > 0, numbers[3] > 0 else {
        throw failure("Invalid SVG viewBox: \(value)")
    }
    return parts
}

func svg(
    _ master: Data, color: String, canvas: String, background: Brand.Appearance? = nil,
    cornerRadius: Double = 0, layer: String? = nil
) throws -> Data {
    let document = try XMLDocument(data: master)
    guard let root = document.rootElement(), let bounds = root.attribute(forName: "viewBox")?.stringValue,
        let definitions = root.elements(forName: "defs").first
    else {
        throw failure("The logo master must have an SVG root and a tightly bounded viewBox.")
    }
    _ = try viewBox(bounds)
    let dimensions = try viewBox(canvas)
    guard cornerRadius.isFinite, cornerRadius >= 0,
        cornerRadius <= min(Double(dimensions[2])!, Double(dimensions[3])!) / 2
    else { throw failure("Invalid homepage icon corner radius.") }
    _ = try channels(color)
    attribute(root, "viewBox", canvas)
    attribute(root, "width", "1024")
    attribute(root, "height", "1024")
    let fills = try root.nodes(forXPath: "descendant-or-self::*[@fill='currentColor' or @stop-color='currentColor']")
    guard !fills.isEmpty else { throw failure("Use currentColor for the master logo's ink.") }
    for case let element as XMLElement in fills {
        for name in ["fill", "stop-color"] where element.attribute(forName: name)?.stringValue == "currentColor" {
            attribute(element, name, color)
        }
    }
    if let layer {
        let groups = root.elements(forName: "g")
        guard groups.contains(where: { $0.attribute(forName: "id")?.stringValue == layer }) else {
            throw failure("Missing brand layer: \(layer)")
        }
        for group in groups where group.attribute(forName: "id")?.stringValue != layer { group.detach() }
    }
    if let background {
        _ = try channels(background.background)
        _ = try channels(background.backgroundEnd)
        let gradient = XMLElement(name: "linearGradient")
        for (name, value) in [("id", "brand-background"), ("x1", "0"), ("y1", "0"), ("x2", "0"), ("y2", "1")] {
            attribute(gradient, name, value)
        }
        for (offset, color) in [("0", background.background), ("1", background.backgroundEnd)] {
            let stop = XMLElement(name: "stop")
            attribute(stop, "offset", offset)
            attribute(stop, "stop-color", color)
            gradient.addChild(stop)
        }
        definitions.addChild(gradient)
        let rectangle = XMLElement(name: "rect")
        for (name, value) in zip(["x", "y", "width", "height"], dimensions) {
            attribute(rectangle, name, value)
        }
        attribute(rectangle, "fill", "url(#brand-background)")
        if cornerRadius > 0 { attribute(rectangle, "rx", String(cornerRadius)) }
        root.insertChild(rectangle, at: 0)
    }
    document.insertChild(
        XMLNode.comment(withStringValue: " Generated by build_brand_assets.swift; edit design/brand sources. ")
            as! XMLNode, at: 0)
    return document.xmlData(options: .nodePrettyPrint) + Data("\n".utf8)
}

func png(_ svg: Data) throws -> Data {
    guard let image = NSImage(data: svg),
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0),
        let context = NSGraphicsContext(bitmapImageRep: bitmap)
    else { throw failure("Unable to rasterize the logo SVG.") }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    context.cgContext.clear(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    image.draw(
        in: NSRect(x: 0, y: 0, width: 1024, height: 1024), from: .zero, operation: .copy, fraction: 1,
        respectFlipped: false, hints: nil)
    NSGraphicsContext.restoreGraphicsState()
    guard
        let result = bitmap.converting(to: .sRGB, renderingIntent: .default)?.representation(
            using: .png, properties: [:])
    else { throw failure("Unable to encode the logo as an sRGB PNG.") }
    return result
}

func generate(_ root: URL) throws -> [String: Data] {
    let source = root.appendingPathComponent("design/brand")
    let master = try Data(contentsOf: source.appendingPathComponent("mark.svg"))
    let brand = try JSONDecoder().decode(
        Brand.self, from: Data(contentsOf: source.appendingPathComponent("brand.json")))
    _ = try viewBox(brand.iconViewBox)
    let production = "design/brand/production"
    let assets = "MarkdownIt/Assets.xcassets"
    var files: [String: Data] = [:]
    let variants: [(String, Brand.Appearance?)] = [
        ("mark", nil),
        ("app-icon-light", brand.colors.light),
        ("app-icon-dark", brand.colors.dark),
    ]
    for (name, background) in variants {
        let vector = try svg(master, color: brand.ink, canvas: brand.iconViewBox, background: background)
        files["\(production)/\(name).svg"] = vector
        files["\(production)/\(name).png"] = try png(vector)
    }
    let icon = "\(production)/\(brand.name).icon"
    var layers: [[String: Any]] = []
    for (name, identifier) in [("01-Paper", "paper"), ("02-Content", "content"), ("03-PageTurn", "page-turn")] {
        let filename = "\(name).svg"
        files["\(icon)/Assets/\(filename)"] = try svg(
            master, color: brand.ink, canvas: brand.iconViewBox, layer: identifier)
        layers.append([
            "image-name": filename, "name": name,
            "fill-specializations": [["value": "none"]],
            "glass-specializations": [["value": false]],
        ])
    }
    files["\(icon)/icon.json"] = try json([
        "groups": [
            [
                // Icon Composer lists frontmost layers first; SVG paints back-to-front.
                "layers": Array(layers.reversed()),
                "shadow": ["kind": "none", "opacity": 0],
                "translucency": ["enabled": false, "value": 0],
                "specular": false,
            ]
        ],
        "supported-platforms": ["squares": "shared"],
        "fill-specializations": [
            ["value": try iconBackground(brand.colors.light)],
            ["appearance": "dark", "value": try iconBackground(brand.colors.dark)],
        ],
    ])
    let info: [String: Any] = ["author": "xcode", "version": 1]
    let home = "\(assets)/BrandMark.imageset"
    for (name, appearance) in [("BrandMark", brand.colors.light), ("BrandMark-dark", brand.colors.dark)] {
        files["\(home)/\(name).svg"] = try svg(
            master, color: brand.ink, canvas: brand.iconViewBox, background: appearance,
            cornerRadius: brand.homeCornerRadius)
    }
    files["\(assets)/BrandMark.imageset/Contents.json"] = try json([
        "images": [
            ["filename": "BrandMark.svg", "idiom": "universal"],
            [
                "filename": "BrandMark-dark.svg", "idiom": "universal",
                "appearances": [["appearance": "luminosity", "value": "dark"]],
            ],
        ],
        "info": info,
        "properties": ["preserves-vector-representation": true, "template-rendering-intent": "original"],
    ])
    files["\(production)/exports.json"] = try json([
        "name": brand.name,
        "source": "../mark.svg",
        "configuration": "../brand.json",
        "process": "Generated by scripts/build_brand_assets.swift; rasterized with macOS AppKit.",
        "rasterSize": [1024, 1024],
        "colorSpace": "sRGB",
        "nativeIcon": "\(brand.name).icon",
        "exports": variants.flatMap { ["\($0.0).svg", "\($0.0).png"] },
        "masking": "Unmasked squares. The system applies enclosure and appearance through the .icon package.",
    ])
    return files
}

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    guard arguments.isEmpty || arguments == ["--check"] else {
        throw failure("Usage: swift scripts/build_brand_assets.swift [--check]")
    }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .resolvingSymlinksInPath()
    let files = try generate(root)
    let manager = FileManager.default
    let roots = ["design/brand/production", "MarkdownIt/Assets.xcassets/BrandMark.imageset"]
    var extras: [String] = []
    for directory in roots {
        let url = root.appendingPathComponent(directory)
        let enumerator = manager.enumerator(atPath: url.path)
        while let name = enumerator?.nextObject() as? String {
            if name.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
            let file = url.appendingPathComponent(name)
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let relative = "\(directory)/\(name)"
            if files[relative] == nil { extras.append(relative) }
        }
    }
    let changed = files.keys.sorted().filter { (try? Data(contentsOf: root.appendingPathComponent($0))) != files[$0] }
    if arguments == ["--check"] {
        guard changed.isEmpty && extras.isEmpty else {
            throw failure(
                "Stale brand assets: \((changed + extras).joined(separator: ", ")). Run python3 scripts/build_native_web.py."
            )
        }
        print("Brand assets match the shared SVG master and palette.")
    } else {
        for relative in changed {
            let destination = root.appendingPathComponent(relative)
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files[relative]!.write(to: destination, options: .atomic)
        }
        for relative in extras { try manager.removeItem(at: root.appendingPathComponent(relative)) }
        print("Generated brand assets from design/brand/mark.svg and brand.json.")
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
