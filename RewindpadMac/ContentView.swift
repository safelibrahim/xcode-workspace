import SwiftUI
import Foundation
import AppKit
import UniformTypeIdentifiers
import CoreImage.CIFilterBuiltins


enum MacPersistentIconStore {
    static let referencePrefix = "launchpad-icon://"

    static var iconsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)

        return appSupport
            .appendingPathComponent("Launchpad", isDirectory: true)
            .appendingPathComponent("CustomIcons", isDirectory: true)
    }

    static func isPersistentReference(_ value: String?) -> Bool {
        guard let value else {
            return false
        }

        return value.hasPrefix(referencePrefix)
    }

    static func persistentReference(for value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        if isPersistentReference(value) {
            return value
        }

        return saveBase64Immediately(value)
    }

    static func saveBase64Immediately(_ base64: String?) -> String? {
        guard let base64, !base64.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        if isPersistentReference(base64) {
            return base64
        }

        guard let data = Data(base64Encoded: base64) else {
            return nil
        }

        return saveDataImmediately(data)
    }

    static func saveDataImmediately(_ data: Data) -> String? {
        do {
            try FileManager.default.createDirectory(at: iconsDirectory, withIntermediateDirectories: true)
            let fileName = UUID().uuidString + ".png"
            let fileURL = iconsDirectory.appendingPathComponent(fileName, isDirectory: false)
            try data.write(to: fileURL, options: [.atomic])
            return referencePrefix + fileName
        } catch {
            #if DEBUG
            print("Launchpad custom icon save failed:", error.localizedDescription)
            #endif
            return nil
        }
    }

    static func fileURL(for value: String?) -> URL? {
        guard let value, isPersistentReference(value) else {
            return nil
        }

        let fileName = String(value.dropFirst(referencePrefix.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        guard !fileName.isEmpty else {
            return nil
        }

        return iconsDirectory.appendingPathComponent(fileName, isDirectory: false)
    }

    static func data(for value: String?) -> Data? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        if let fileURL = fileURL(for: value) {
            return try? Data(contentsOf: fileURL)
        }

        return Data(base64Encoded: value, options: .ignoreUnknownCharacters)
    }

    static func image(for value: String?) -> NSImage? {
        guard let data = data(for: value) else {
            return nil
        }

        return NSImage(data: data)
    }

    static func base64ForTransport(_ value: String?) -> String? {
        guard let data = data(for: value) else {
            return nil
        }

        return data.base64EncodedString()
    }
}

final class MacIconImageCache {
    static let shared = MacIconImageCache()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 160
        cache.totalCostLimit = 28 * 1024 * 1024
    }

    func image(forBase64 iconData: String?) -> NSImage? {
        guard let iconData, !iconData.isEmpty else { return nil }

        let key = "custom-icon-\(iconData)" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }

        guard let image = MacPersistentIconStore.image(for: iconData) else {
            return nil
        }

        cache.setObject(image, forKey: key, cost: 256 * 256 * 4)
        return image
    }



    func image(forAppPath path: String?) -> NSImage? {
        guard let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let expanded = (path as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded) else { return nil }

        let key = "path-\(expanded)" as NSString
        if let cached = cache.object(forKey: key) { return cached }

        let image = NSWorkspace.shared.icon(forFile: expanded)
        image.size = NSSize(width: 96, height: 96)
        cache.setObject(image, forKey: key, cost: 96 * 96 * 4)
        return image
    }

    func shortcutsAppIcon() -> NSImage? {
        for path in ["/System/Applications/Shortcuts.app", "/Applications/Shortcuts.app"] {
            if let image = image(forAppPath: path) { return image }
        }
        return nil
    }
}

enum MacCustomIconSource {
    static func chooseImageBase64() -> String? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .gif]
        panel.title = "Choose Custom Icon"
        panel.prompt = "Choose"

        guard panel.runModal() == .OK, let url = panel.url else {
            return nil
        }

        return imageBase64(from: url)
    }

    static func imageBase64(from url: URL) -> String? {
        guard let image = NSImage(contentsOf: url),
              let base64 = pngBase64(from: image) else {
            return nil
        }

        return MacPersistentIconStore.saveBase64Immediately(base64)
    }



    static func fetchWebsiteLogoBase64(for rawURL: String, completion: @escaping (String?) -> Void) {
        guard let pageURL = normalizedURL(rawURL),
              let domain = cleanDomain(from: pageURL),
              !domain.isEmpty else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        let candidates = websiteLogoCandidates(for: domain)
        fetchFirstValidWebsiteLogo(from: candidates, completion: completion)
    }

    private static func normalizedURL(_ value: String) -> URL? {
        var raw = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        raw = raw.replacingOccurrences(of: " ", with: "")

        if !raw.lowercased().hasPrefix("http://") && !raw.lowercased().hasPrefix("https://") {
            raw = "https://" + raw
        }

        return URL(string: raw)
    }

    private static func cleanDomain(from url: URL) -> String? {
        guard var host = url.host?.lowercased(), !host.isEmpty else {
            return nil
        }

        host = host.trimmingCharacters(in: CharacterSet(charactersIn: ". /"))
        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }

        // Clearbit and Google both expect a clean domain only: no scheme, path, query, or slash.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
        let scalars = host.unicodeScalars.filter { allowed.contains($0) }
        let cleaned = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-"))

        guard cleaned.contains(".") else {
            return nil
        }

        return cleaned
    }

    private static func websiteLogoCandidates(for domain: String) -> [URL] {
        var urls: [URL] = []

        // 1. Clearbit first — clean high-resolution logo for many major sites.
        var clearbit = URLComponents()
        clearbit.scheme = "https"
        clearbit.host = "logo.clearbit.com"
        clearbit.path = "/" + domain
        clearbit.queryItems = [URLQueryItem(name: "size", value: "256")]
        if let url = clearbit.url {
            urls.append(url)
        }

        // 2. Google high-size fallback. Avoid direct .ico favicon files entirely.
        var google = URLComponents()
        google.scheme = "https"
        google.host = "www.google.com"
        google.path = "/s2/favicons"
        google.queryItems = [
            URLQueryItem(name: "domain", value: domain),
            URLQueryItem(name: "sz", value: "256")
        ]
        if let url = google.url {
            urls.append(url)
        }

        return urls
    }

    private static func fetchFirstValidWebsiteLogo(from urls: [URL], completion: @escaping (String?) -> Void) {
        guard let url = urls.first else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3.0
        request.cachePolicy = .returnCacheDataElseLoad
        request.setValue("image/png,image/jpeg,image/webp,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 Launchpad", forHTTPHeaderField: "User-Agent")

        #if DEBUG
        print("Launchpad Website Icon URL:", url.absoluteString)
        #endif

        URLSession.shared.dataTask(with: request) { data, response, _ in
            let nextURLs = Array(urls.dropFirst())

            if let http = response as? HTTPURLResponse {
                #if DEBUG
                print("Launchpad Website Icon status:", http.statusCode, url.absoluteString)
                #endif

                if !(200...299).contains(http.statusCode) {
                    fetchFirstValidWebsiteLogo(from: nextURLs, completion: completion)
                    return
                }
            }

            guard let data,
                  !data.isEmpty,
                  data.count <= 500_000,
                  let image = NSImage(data: data),
                  image.size.width >= 16,
                  image.size.height >= 16,
                  let base64 = pngBase64(from: image) else {
                #if DEBUG
                print("Launchpad Website Icon decode failed:", url.absoluteString)
                #endif
                fetchFirstValidWebsiteLogo(from: nextURLs, completion: completion)
                return
            }

            DispatchQueue.main.async {
                completion(MacPersistentIconStore.saveBase64Immediately(base64))
            }
        }.resume()
    }

    static func emojiBase64(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let text = String(trimmed.prefix(2))
        let size = NSSize(width: 256, height: 256)
        let image = NSImage(size: size)

        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 168),
            .paragraphStyle: paragraphStyle
        ]

        let attributed = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributed.size()
        let rect = NSRect(
            x: 0,
            y: (size.height - textSize.height) / 2 - 8,
            width: size.width,
            height: textSize.height
        )

        attributed.draw(in: rect)
        image.unlockFocus()

        guard let base64 = pngBase64(from: image) else {
            return nil
        }

        return MacPersistentIconStore.saveBase64Immediately(base64)
    }



    private static func pngBase64(from image: NSImage) -> String? {
        let size = NSSize(width: 128, height: 128)
        let output = NSImage(size: size)

        output.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1)
        output.unlockFocus()

        guard
            let tiffData = output.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffData),
            let pngData = bitmap.representation(using: .png, properties: [:])
        else {
            return nil
        }

        let base64 = pngData.base64EncodedString()
        return base64.count <= 140_000 ? base64 : nil
    }
}

struct MacLiquidBackground: View {
    var body: some View {
        MacNativeWindowMaterial()
            .ignoresSafeArea()
    }
}

// MARK: - Workspace Management

struct AppGroupsManagementView: View {
    @ObservedObject var server: RewindpadServer
    @State private var showCreator = false
    @State private var editingGroup: AppGroup? = nil

    private let columns = [GridItem(.adaptive(minimum: 260, maximum: 340), spacing: 14)]

    var body: some View {
        ZStack {
            MacLiquidBackground()

            if server.appGroups.isEmpty {
                workspaceEmptyState
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    // Fixed header — only the cards below scroll.
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Workspaces")
                                .font(.title.weight(.bold))
                            Text("Launch groups of apps with one click.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            editingGroup = nil
                            showCreator = true
                        } label: {
                            Label("New Workspace", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 22)
                    .padding(.bottom, 14)

                    Rectangle()
                        .fill(Color.primary.opacity(0.14))
                        .frame(height: 1)

                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(server.appGroups) { group in
                                let entries = group.apps.filter { !($0.isShortcut && $0.shortcutRunMode == .background) }
                                let screen = NSScreen.screens.first
                                let hasConflict = screen.map { server.conflictPair(entries: entries, layout: group.layout, screen: $0) != nil } ?? false
                                AppGroupCard(group: group, hasConflict: hasConflict, onLaunch: {
                                    server.launchAppGroup(id: group.id)
                                }) {
                                    editingGroup = group
                                    showCreator = true
                                } onDelete: {
                                    server.removeAppGroup(id: group.id)
                                }
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 18)
                        .padding(.bottom, 24)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(isPresented: $showCreator) {
            AppGroupCreatorSheet(
                server: server,
                existing: editingGroup,
                onDelete: editingGroup.map { grp in { server.removeAppGroup(id: grp.id); showCreator = false } }
            ) { group in
                if editingGroup != nil { server.updateAppGroup(group) }
                else { server.addAppGroup(group) }
                showCreator = false
                editingGroup = nil
            }
            .id(editingGroup?.id ?? "new-workspace")
        }
    }

    private var workspaceEmptyState: some View {
        VStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.accentColor.opacity(0.10))
                    .frame(width: 80, height: 80)
                Image(systemName: "rectangle.3.group")
                    .font(.system(size: 32, weight: .light))
                    .foregroundStyle(.blue)
            }
            VStack(spacing: 8) {
                Text("No Workspaces")
                    .font(.title3.weight(.bold))
                Text("Save groups of apps with layouts.\nLaunch them instantly from your iPhone.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                editingGroup = nil
                showCreator = true
            } label: {
                Label("Create Workspace", systemImage: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(Color.accentColor, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Workspace Card

struct AppGroupCard: View {
    let group: AppGroup
    let hasConflict: Bool
    let onLaunch: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false
    @State private var showDeleteConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            AppGroupLayoutPreview(group: group)
                .frame(height: 140)
                .clipShape(UnevenRoundedRectangle(
                    topLeadingRadius: 16, bottomLeadingRadius: 0,
                    bottomTrailingRadius: 0, topTrailingRadius: 16, style: .continuous))

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.name)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    if let label = group.hotkeyLabel {
                        Text(label)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    if hasConflict {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(nsColor: .systemOrange))
                            .help("Window sizes conflict — edit to fix")
                    }
                    Button(action: onLaunch) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background(hasConflict ? Color.secondary.opacity(0.35) : Color.accentColor, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(hasConflict)
                    .help(hasConflict ? "Fix the window size conflict before launching" : "Launch Workspace")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.regularMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isHovered ? Color.accentColor.opacity(0.45) : Color.primary.opacity(0.09), lineWidth: 1)
        )
        .shadow(color: .black.opacity(isHovered ? 0.18 : 0.08), radius: isHovered ? 14 : 5, y: 3)
        .scaleEffect(isHovered ? 1.012 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.82), value: isHovered)
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onEdit)
        .contextMenu {
            Button("Edit Workspace", action: onEdit)
            Divider()
            Button("Delete Workspace", role: .destructive) { showDeleteConfirm = true }
        }
        .confirmationDialog("Delete \"\(group.name)\"?", isPresented: $showDeleteConfirm) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        }
    }
}

// MARK: - Layout Preview Canvas

struct AppGroupLayoutPreview: View {
    let group: AppGroup
    var conflicting: Bool = false
    @State private var collide = false

    // Fixed deep dark background — never washed out in light mode
    private static let bgTop    = Color(red: 0.10, green: 0.09, blue: 0.15)
    private static let bgBottom = Color(red: 0.06, green: 0.06, blue: 0.10)

    private var conflictIsHorizontal: Bool {
        switch group.layout {
        case .split1x1, .split1x2, .split2x1: return true
        default: return false
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Always-dark gradient background
                LinearGradient(
                    colors: [Self.bgTop, Self.bgBottom],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )

                // Layout panes — keyed by layout so SwiftUI transitions on change
                layoutDiagram(in: geo.size)
                    .id(group.layout)
                    .transition(
                        .asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.96)),
                            removal:   .opacity.combined(with: .scale(scale: 1.03))
                        )
                    )
                    .animation(.spring(response: 0.38, dampingFraction: 0.82), value: group.layout)
            }
        }
        .onChange(of: conflicting) { _, isConflicting in
            if isConflicting {
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { collide = true }
            } else {
                withAnimation(.spring(duration: 0.3)) { collide = false }
            }
        }
        .onAppear {
            if conflicting {
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) { collide = true }
            }
        }
    }

    @ViewBuilder
    private func layoutDiagram(in size: CGSize) -> some View {
        let pad: CGFloat = 10
        let gap: CGFloat = 5
        let c = CGRect(x: pad, y: pad, width: size.width - pad * 2, height: size.height - pad * 2)
        let apps = group.apps.filter { !($0.isShortcut && $0.shortcutRunMode == .background) }

        switch group.layout {
        case .split1x1:
            let hw = (c.width - gap) / 2
            windowPane(CGRect(x: c.minX,        y: c.minY, width: hw,              height: c.height), appIndex: 0, apps: apps)
            windowPane(CGRect(x: c.minX+hw+gap, y: c.minY, width: c.width-hw-gap,  height: c.height), appIndex: 1, apps: apps)
        case .split1x1v:
            let hh = (c.height - gap) / 2
            windowPane(CGRect(x: c.minX, y: c.minY,        width: c.width, height: hh),             appIndex: 0, apps: apps)
            windowPane(CGRect(x: c.minX, y: c.minY+hh+gap, width: c.width, height: c.height-hh-gap),appIndex: 1, apps: apps)
        case .split1x2:
            let mw = (c.width * 0.60).rounded()
            let sw = c.width - mw - gap
            let sc = apps.count >= 2 ? apps.count - 1 : 2
            let sh = (c.height - gap * CGFloat(sc - 1)) / CGFloat(sc)
            windowPane(CGRect(x: c.minX, y: c.minY, width: mw, height: c.height), appIndex: 0, apps: apps)
            ForEach(0..<sc, id: \.self) { i in
                windowPane(CGRect(x: c.minX+mw+gap, y: c.minY+CGFloat(i)*(sh+gap), width: sw, height: sh), appIndex: i+1, apps: apps)
            }
        case .split2x1:
            let sw = (c.width * 0.40).rounded()
            let mw = c.width - sw - gap
            let sc = apps.count >= 2 ? apps.count - 1 : 2
            let sh = (c.height - gap * CGFloat(sc - 1)) / CGFloat(sc)
            ForEach(0..<sc, id: \.self) { i in
                windowPane(CGRect(x: c.minX, y: c.minY+CGFloat(i)*(sh+gap), width: sw, height: sh), appIndex: i+1, apps: apps)
            }
            windowPane(CGRect(x: c.minX+sw+gap, y: c.minY, width: mw, height: c.height), appIndex: 0, apps: apps)
        case .split1x2h:
            let mh = (c.height * 0.60).rounded()
            let bh = c.height - mh - gap
            let bc = apps.count >= 2 ? apps.count - 1 : 2
            let bw = (c.width - gap * CGFloat(bc - 1)) / CGFloat(bc)
            windowPane(CGRect(x: c.minX, y: c.minY, width: c.width, height: mh), appIndex: 0, apps: apps)
            ForEach(0..<bc, id: \.self) { i in
                windowPane(CGRect(x: c.minX+CGFloat(i)*(bw+gap), y: c.minY+mh+gap, width: bw, height: bh), appIndex: i+1, apps: apps)
            }
        case .grid2x2:
            let hw = (c.width - gap) / 2
            let hh = (c.height - gap) / 2
            let slots: [CGRect] = [
                CGRect(x: c.minX,          y: c.minY,          width: hw,               height: hh),
                CGRect(x: c.minX+hw+gap,   y: c.minY,          width: c.width-hw-gap,   height: hh),
                CGRect(x: c.minX,          y: c.minY+hh+gap,   width: hw,               height: c.height-hh-gap),
                CGRect(x: c.minX+hw+gap,   y: c.minY+hh+gap,   width: c.width-hw-gap,   height: c.height-hh-gap),
            ]
            ForEach(0..<4, id: \.self) { i in
                windowPane(slots[i], appIndex: i, apps: apps)
            }
        }
    }

    @ViewBuilder
    private func windowPane(_ frame: CGRect, appIndex: Int, apps: [AppGroupEntry]) -> some View {
        let isPrimary = apps.indices.contains(appIndex) && apps[appIndex].id == group.primaryAppID
        let entry: AppGroupEntry? = apps.indices.contains(appIndex) ? apps[appIndex] : nil
        let isColliding = conflicting && appIndex < 2
        let push: CGFloat = 6
        let dx: CGFloat = isColliding ? (appIndex == 0 ? (conflictIsHorizontal ? push : 0) : (conflictIsHorizontal ? -push : 0)) : 0
        let dy: CGFloat = isColliding ? (appIndex == 0 ? (conflictIsHorizontal ? 0 : push) : (conflictIsHorizontal ? 0 : -push)) : 0

        let iconMax: CGFloat = min(frame.width * 0.32, 52)

        ZStack {
            // Pane fill
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(
                    isColliding && collide
                    ? Color.red.opacity(0.22)
                    : isPrimary
                        ? Color.white.opacity(0.16)
                        : Color.white.opacity(0.08)
                )
            // Pane border
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isColliding && collide
                    ? Color.red.opacity(0.9)
                    : Color.white.opacity(isPrimary ? 0.30 : 0.14),
                    lineWidth: isPrimary ? 1.0 : 0.75
                )

            if let entry {
                VStack(spacing: 5) {
                    if let img = MacIconImageCache.shared.image(forAppPath: entry.path) {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: iconMax, height: iconMax)
                            .shadow(color: .black.opacity(0.45), radius: 6, y: 3)
                            .transition(.scale(scale: 0.7).combined(with: .opacity))
                    } else {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.white.opacity(0.15))
                            .frame(width: iconMax * 0.75, height: iconMax * 0.75)
                    }
                    if frame.height > 60 {
                        Text(entry.appName)
                            .font(.system(size: max(min(frame.width * 0.08, 11), 8), weight: .medium))
                            .foregroundStyle(.white.opacity(0.70))
                            .lineLimit(1)
                            .animation(.spring(response: 0.3), value: entry.appName)
                    }
                }
                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: entry.id)
            }

        }
        .frame(width: frame.width, height: frame.height)
        .position(x: frame.midX + (collide ? dx : 0), y: frame.midY + (collide ? dy : 0))
    }
}

// MARK: - Layout Icon

struct LayoutIconView: View {
    let layout: AppGroupLayout
    var size: CGFloat = 20
    var color: Color = .primary
    var cornerRadius: CGFloat = 1.5

    var body: some View {
        Canvas { ctx, s in
            let gap: CGFloat = max(1, size * 0.07)
            let r = cornerRadius
            func pane(_ rect: CGRect, alpha: CGFloat = 1) {
                let p = Path(roundedRect: rect, cornerRadius: r)
                ctx.fill(p, with: .color(color.opacity(alpha)))
            }
            switch layout {
            case .split1x1:
                let hw = (s.width - gap) / 2
                pane(CGRect(x: 0, y: 0, width: hw, height: s.height))
                pane(CGRect(x: hw+gap, y: 0, width: s.width-hw-gap, height: s.height), alpha: 0.55)
            case .split1x1v:
                let hh = (s.height - gap) / 2
                pane(CGRect(x: 0, y: 0, width: s.width, height: hh))
                pane(CGRect(x: 0, y: hh+gap, width: s.width, height: s.height-hh-gap), alpha: 0.55)
            case .split1x2:
                let mw = (s.width * 0.58).rounded()
                let sw = s.width - mw - gap
                let hh = (s.height - gap) / 2
                pane(CGRect(x: 0, y: 0, width: mw, height: s.height))
                pane(CGRect(x: mw+gap, y: 0, width: sw, height: hh), alpha: 0.55)
                pane(CGRect(x: mw+gap, y: hh+gap, width: sw, height: s.height-hh-gap), alpha: 0.55)
            case .split2x1:
                let sw = (s.width * 0.38).rounded()
                let mw = s.width - sw - gap
                let hh = (s.height - gap) / 2
                pane(CGRect(x: 0, y: 0, width: sw, height: hh), alpha: 0.55)
                pane(CGRect(x: 0, y: hh+gap, width: sw, height: s.height-hh-gap), alpha: 0.55)
                pane(CGRect(x: sw+gap, y: 0, width: mw, height: s.height))
            case .split1x2h:
                let mh = (s.height * 0.58).rounded()
                let bh = s.height - mh - gap
                let hw = (s.width - gap) / 2
                pane(CGRect(x: 0, y: 0, width: s.width, height: mh))
                pane(CGRect(x: 0, y: mh+gap, width: hw, height: bh), alpha: 0.55)
                pane(CGRect(x: hw+gap, y: mh+gap, width: s.width-hw-gap, height: bh), alpha: 0.55)
            case .grid2x2:
                let hw = (s.width - gap) / 2
                let hh = (s.height - gap) / 2
                pane(CGRect(x: 0, y: 0, width: hw, height: hh))
                pane(CGRect(x: hw+gap, y: 0, width: s.width-hw-gap, height: hh), alpha: 0.7)
                pane(CGRect(x: 0, y: hh+gap, width: hw, height: s.height-hh-gap), alpha: 0.7)
                pane(CGRect(x: hw+gap, y: hh+gap, width: s.width-hw-gap, height: s.height-hh-gap), alpha: 0.5)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Workspace Group Icon

struct AppGroupMacIcon: View {
    let group: AppGroup
    let size: CGFloat

    private static let palettes: [([Color], Color)] = [
        ([Color(hex: "#1a1f3a"), Color(hex: "#0d1628")], Color(hex: "#4a90d9")),
        ([Color(hex: "#1f2a1a"), Color(hex: "#0e1a0d")], Color(hex: "#4aba6e")),
        ([Color(hex: "#2a1a2e"), Color(hex: "#180d1f")], Color(hex: "#a855f7")),
        ([Color(hex: "#2a1e14"), Color(hex: "#1a0f08")], Color(hex: "#f59e0b")),
        ([Color(hex: "#1f1a2a"), Color(hex: "#100d1a")], Color(hex: "#ec4899")),
    ]
    private var palette: ([Color], Color) { Self.palettes[abs(group.id.hashValue) % Self.palettes.count] }
    private var accentColor: Color { palette.1 }
    private var cornerRadius: CGFloat { size * 0.224 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(LinearGradient(colors: [accentColor, accentColor.opacity(0.72)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
                }
                .shadow(color: accentColor.opacity(0.4), radius: 8, y: 3)
            LayoutIconView(layout: group.layout, size: size * 0.52, color: .white, cornerRadius: cornerRadius * 0.25)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - FlowRow

struct FlowRow<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content
    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 100, maximum: 200), spacing: spacing)],
            alignment: .leading, spacing: spacing
        ) { content() }
    }
}

struct ChipFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let w = proposal.width ?? 0
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x + s.width > w, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
        return CGSize(width: w, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for sv in subviews {
            let s = sv.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            sv.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}

// MARK: - Workspace Creator Sheet
// MARK: - Workspace Creator Sheet

struct AppGroupCreatorSheet: View {
    @ObservedObject var server: RewindpadServer
    let existing: AppGroup?
    let onDelete: (() -> Void)?
    let onSave: (AppGroup) -> Void

    @State private var name: String
    @State private var icon: String
    @State private var selectedApps: [AppGroupEntry]
    @State private var layout: AppGroupLayout
    @State private var primaryAppID: String?
    @State private var stopBehavior: AppGroupStopBehavior
    @State private var hotkeyIndex: Int?
    @State private var urlInput = ""
    @State private var browserChoice: BrowserChoice = .safari
    @State private var searchText = ""
    @State private var shortcutSearchText = ""
    @State private var showDeleteConfirm = false
    @State private var currentStep: Int = 0
    @State private var stepForward: Bool = true
    @State private var appsTab: Int = 0
    @State private var cachedSortedApps: [AvailableApp] = []
    @State private var clashingCandidateIDs: Set<String> = []
    @State private var pendingShortcut: AppleShortcut? = nil
    @State private var showSaveBlocked = false
    @State private var isVerifyingFit = false
    @State private var recentLinks: [RecentLinkItem] = []

    struct RecentLinkItem: Codable, Identifiable, Equatable {
        var id: String { url }
        let url: String
        let browser: String
    }
    @Environment(\.dismiss) private var dismiss

    // 5 steps matching iPhone app
    private let stepTitles    = ["Name", "Layout", "Apps", "Order", "Settings"]
    private let stepHeadings  = ["Name your Workspace", "Choose your layout", "Add your apps", "Set your window order", "Finish your Workspace"]
    private let stepSubtitles = [
        "Give this environment a clear, memorable name.",
        "Pick how your windows will be arranged on screen.",
        "Add apps, links, and shortcuts that launch together.",
        "Drag to reorder. The first window gets the largest slot.",
        "Decide what happens when you stop this Workspace."
    ]

    init(server: RewindpadServer, existing: AppGroup?, onDelete: (() -> Void)? = nil, onSave: @escaping (AppGroup) -> Void) {
        self.server = server
        self.existing = existing
        self.onDelete = onDelete
        self.onSave = onSave
        _name         = State(initialValue: existing?.name ?? "")
        _icon         = State(initialValue: existing?.icon ?? "rectangle.3.group")
        _selectedApps = State(initialValue: existing?.apps ?? [])
        _layout       = State(initialValue: existing?.layout ?? .split1x1)
        _primaryAppID = State(initialValue: existing?.primaryAppID)
        _stopBehavior = State(initialValue: existing?.stopBehavior ?? .quit)
        _hotkeyIndex  = State(initialValue: existing?.hotkeyIndex)
    }

    private var filteredApps: [AvailableApp] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return cachedSortedApps }
        return cachedSortedApps.filter { $0.name.lowercased().contains(q) }
    }

    private var previewGroup: AppGroup {
        AppGroup(id: existing?.id ?? "preview",
                 name: name.isEmpty ? "My Workspace" : name,
                 icon: icon, apps: selectedApps, layout: layout,
                 primaryAppID: primaryAppID ?? selectedApps.first?.id,
                 createdAt: existing?.createdAt ?? Date())
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !selectedApps.isEmpty
            && hardConflict == nil
            && visibleSelectedCount <= layoutCapacity
            && slotIssues.isEmpty
    }

    /// How many windows the chosen layout can hold.
    private var layoutCapacity: Int {
        switch layout {
        case .split1x1, .split1x1v: return 2
        case .split1x2, .split2x1, .split1x2h: return 3
        case .grid2x2: return 4
        }
    }

    /// Apps that occupy a window slot (background shortcuts don't).
    private var visibleSelectedCount: Int {
        selectedApps.filter { !($0.isShortcut && $0.shortcutRunMode == .background) }.count
    }

    private var layoutIsFull: Bool { visibleSelectedCount >= layoutCapacity }

    /// Per-slot fit problems at the layout's standard split ratios —
    /// catches a wide-minimum app dropped into a small slot after reordering.
    private var slotIssues: [CompatibilityIssue] {
        guard let screen = NSScreen.screens.first else { return [] }
        let vis = selectedApps.filter { !($0.isShortcut && $0.shortcutRunMode == .background) }
        guard vis.count >= 2 else { return [] }
        return ScreenCompatibilityChecker.check(
            apps: vis, layout: layout,
            splitRatio: 0.6, splitRatioSecondary: 0.5,
            screen: screen,
            minSize: { entry in
                let s = server.minSlotSize(for: entry)
                return (s.width > 40 || s.height > 40) ? s : nil
            }
        )
    }

    private var hardConflict: (String, String)? {
        guard let screen = NSScreen.screens.first else { return nil }
        let vis = selectedApps.filter { !($0.isShortcut && $0.shortcutRunMode == .background) }
        return server.conflictPair(entries: vis, layout: layout, screen: screen)
    }

    private var isLastStep: Bool { currentStep == stepTitles.count - 1 }
    private var canAdvance: Bool {
        switch currentStep {
        case 0: return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case 1, 2: return hardConflict == nil && visibleSelectedCount <= layoutCapacity
        case 3: return hardConflict == nil && visibleSelectedCount <= layoutCapacity && slotIssues.isEmpty
        default: return true
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // ── Left — wizard steps ───────────────────────────────────────
            VStack(spacing: 0) {
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: 0) {
                        // Title block — macOS text styles
                        VStack(alignment: .leading, spacing: 4) {
                            Text(stepHeadings[currentStep])
                                .font(.title2.weight(.semibold))
                            Text(stepSubtitles[currentStep])
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.bottom, 16)

                        Rectangle()
                            .fill(Color.primary.opacity(0.14))
                            .frame(height: 1)
                            .padding(.horizontal, -24)
                            .padding(.bottom, 20)

                        // Step body — only inner lists/grids scroll.
                        stepContent

                        Spacer(minLength: 0)
                    }
                    .padding(24)
                    .id(currentStep)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(x: stepForward ? 28 : -28)),
                        removal:   .opacity.combined(with: .offset(x: stepForward ? -28 : 28))
                    ))
                }
                .animation(.spring(response: 0.32, dampingFraction: 0.88), value: currentStep)
                .frame(maxHeight: .infinity, alignment: .top)
                .clipped()

                Divider()

                navigationFooter
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
            }
            .frame(width: 520)
            .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            // ── Right — live preview ──────────────────────────────────────
            previewPane
                .frame(width: 340)
        }
        .frame(width: 860, height: 720)
        .task {
            // Quietly record AXMinSize for everything currently running, so
            // fit predictions keep getting better over time.
            server.harvestMinSizesFromRunningApps()
            guard cachedSortedApps.isEmpty else { return }
            let sorted = await Task.detached(priority: .userInitiated) {
                server.availableApps.sorted { $0.name < $1.name }
            }.value
            cachedSortedApps = sorted
            recomputeClashes()
            loadRecentLinks()
        }
        .onChange(of: selectedApps) { _, _ in recomputeClashes() }
        .onChange(of: layout) { _, _ in recomputeClashes() }
    }

    /// Which not-yet-selected apps would create a size conflict if added,
    /// given the current selection and layout. Drives the per-cell warning.
    private func recomputeClashes() {
        guard let screen = NSScreen.screens.first else { clashingCandidateIDs = []; return }
        let sel = selectedApps.filter { !($0.isShortcut && $0.shortcutRunMode == .background) }
        guard !sel.isEmpty, !layoutIsFull else { clashingCandidateIDs = []; return }
        let provider: (AppGroupEntry) -> CGSize? = { entry in
            let s = server.minSlotSize(for: entry)
            return (s.width > 40 || s.height > 40) ? s : nil
        }
        var out = Set<String>()
        for app in cachedSortedApps.prefix(120) where !sel.contains(where: { $0.id == app.id }) {
            let entry = AppGroupEntry(id: app.id, appName: app.name, bundleID: app.id, path: app.path)
            let candidate = sel + [entry]
            let ratioConflict = server.conflictPair(entries: candidate, layout: layout, screen: screen) != nil
            let slotConflict = !ScreenCompatibilityChecker.check(
                apps: candidate, layout: layout,
                splitRatio: 0.6, splitRatioSecondary: 0.5,
                screen: screen, minSize: provider
            ).filter { $0.appName == app.name }.isEmpty
            if ratioConflict || slotConflict {
                out.insert(app.id)
            }
        }
        clashingCandidateIDs = out
    }

    // MARK: - Preview pane

    private var previewPane: some View {
        ZStack {
            // Backdrop
            LinearGradient(
                colors: [Color(red: 0.09, green: 0.09, blue: 0.12),
                         Color(red: 0.05, green: 0.05, blue: 0.08)],
                startPoint: .top, endPoint: .bottom
            )

            VStack(spacing: 18) {
                Spacer()

                // Miniature display
                VStack(spacing: 0) {
                    // Menu bar hint
                    HStack(spacing: 4) {
                        Circle().fill(Color.white.opacity(0.25)).frame(width: 4, height: 4)
                        Circle().fill(Color.white.opacity(0.18)).frame(width: 4, height: 4)
                        Circle().fill(Color.white.opacity(0.12)).frame(width: 4, height: 4)
                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 14)
                    .background(Color.white.opacity(0.06))

                    AppGroupLayoutPreview(group: previewGroup, conflicting: (hardConflict != nil || !slotIssues.isEmpty) && (1...3).contains(currentStep))
                }
                .aspectRatio(16.0 / 10.5, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
                .padding(.horizontal, 26)

                // Slot usage — green when exactly full, orange when over
                let overCapacity = visibleSelectedCount > layoutCapacity
                HStack(spacing: 5) {
                    if overCapacity {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    } else if layoutIsFull {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.green)
                    }
                    Text(overCapacity
                         ? "\(visibleSelectedCount) windows — this layout fits \(layoutCapacity)"
                         : "\(visibleSelectedCount) of \(layoutCapacity) windows")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(layoutIsFull ? 0.85 : 0.5))
                        .contentTransition(.numericText(value: Double(visibleSelectedCount)))
                        .animation(.easeInOut(duration: 0.2), value: visibleSelectedCount)
                }

                // Background shortcuts — run on launch, no window slot
                let bgShortcuts = selectedApps.filter { $0.isShortcut && $0.shortcutRunMode == .background }
                if !bgShortcuts.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Runs on launch")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.45))
                        ChipFlowLayout(spacing: 6) {
                            ForEach(bgShortcuts) { entry in
                                HStack(spacing: 5) {
                                    Image(systemName: "bolt.fill")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.white.opacity(0.55))
                                    Text(entry.appName)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.white.opacity(0.8))
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .background(Color.white.opacity(0.07), in: Capsule())
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 26)
                    .padding(.top, 6)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                Spacer()
            }
        }
    }

    // MARK: - Progress bar

    private var progressBar: some View {
        HStack(spacing: 10) {
            Text("Step \(currentStep + 1) of \(stepTitles.count)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
                .contentTransition(.numericText(value: Double(currentStep)))
                .animation(.easeInOut(duration: 0.2), value: currentStep)
            HStack(spacing: 3) {
                ForEach(stepTitles.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(i <= currentStep ? Color.accentColor : Color.primary.opacity(0.12))
                        .frame(height: 3)
                        .animation(.easeInOut(duration: 0.22), value: currentStep)
                }
            }
        }
    }

    // MARK: - Step content

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case 0: stepName
        case 1: stepLayout
        case 2: stepApps
        case 3: stepOrder
        default: stepSettings
        }
    }

    // Step 0 — Name
    private var stepName: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Workspace name")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("e.g. Work Mode, Deep Focus, Design…", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 17))
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            name.isEmpty ? Color.primary.opacity(0.12) : Color.accentColor.opacity(0.55),
                            lineWidth: name.isEmpty ? 1 : 1.5
                        )
                        .animation(.easeInOut(duration: 0.18), value: name.isEmpty)
                )
        }
    }

    // Step 1 — Layout
    private var stepLayout: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Grouped card matching iPhone reference
            VStack(spacing: 0) {
                ForEach(Array(layoutGroups.enumerated()), id: \.element.label) { gi, grp in
                    HStack(alignment: .center, spacing: 16) {
                        Text(grp.label)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .tracking(0.5)
                            .frame(width: 72, alignment: .leading)
                        HStack(spacing: 10) {
                            ForEach(grp.options, id: \.self) { opt in layoutCard(opt) }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                    if gi < layoutGroups.count - 1 {
                        Divider().padding(.leading, 18)
                    }
                }
            }
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))

            if let (a, b) = hardConflict {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.orange)
                        Text("\(a) and \(b) can't fit on this screen together. Choose a different layout or remove an app below.")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ChipFlowLayout(spacing: 6) {
                        ForEach(selectedApps.filter { !($0.isShortcut && $0.shortcutRunMode == .background) }) { entry in
                            Button {
                                withAnimation(.spring(response: 0.25)) {
                                    selectedApps.removeAll { $0.id == entry.id }
                                    if primaryAppID == entry.id { primaryAppID = selectedApps.first?.id }
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    AppGroupAppIcon(path: entry.path, name: entry.appName, size: 18)
                                    Text(entry.appName)
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1)
                                    Image(systemName: "xmark")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .background(Color.primary.opacity(0.06), in: Capsule())
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
                            }
                            .buttonStyle(.plain)
                            .help("Remove \(entry.appName)")
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .transition(.opacity)
            }
        }
    }

    private struct LayoutGroup { let label: String; let options: [AppGroupLayout] }
    private var layoutGroups: [LayoutGroup] {[
        LayoutGroup(label: "Equal Split", options: [.split1x1, .split1x1v]),
        LayoutGroup(label: "Focus",       options: [.split1x2, .split2x1, .split1x2h]),
        LayoutGroup(label: "Grid",        options: [.grid2x2]),
    ]}

    private func layoutCard(_ opt: AppGroupLayout) -> some View {
        let selected = layout == opt
        return Button { withAnimation(.easeInOut(duration: 0.12)) { layout = opt } } label: {
            LayoutIconView(layout: opt, size: 26, color: selected ? .white : Color.accentColor, cornerRadius: 2)
                .frame(width: 52, height: 44)
                .background(selected ? Color.accentColor : Color.accentColor.opacity(0.10),
                            in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(
                    selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 0 : 1))
                .scaleEffect(selected ? 1.04 : 1.0)
                .animation(.spring(response: 0.2, dampingFraction: 0.7), value: selected)
        }
        .buttonStyle(.plain)
        .help(opt.displayName)
    }

    // Step 2 — Apps (tabbed)
    private var stepApps: some View {
        VStack(alignment: .leading, spacing: 16) {
            // ── Sliding-pill tab selector ────────────────────────────────
            sourceToggle
                .padding(.bottom, 4)

            if let (a, b) = hardConflict {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.orange)
                    Text("\(a) and \(b) need more space than this layout allows. Remove one or pick a different layout.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if let issue = slotIssues.first {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.orange)
                    Text("\(issue.appName)'s window won't fit in its spot. You can rearrange windows in the next step, or pick a roomier layout.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if !layoutIsFull && !clashingCandidateIDs.isEmpty && appsTab == 0 {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.accentColor)
                    Text("Some apps are unavailable because they need more screen space than this layout has left. Remove an app or choose a roomier layout to use them.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // ── Tab content ──────────────────────────────────────────────
            if appsTab == 0 {
                appsGridTab
            } else if appsTab == 1 {
                linksTab
            } else {
                shortcutsTab
            }
        }
    }

    // Apps grid — Apple app-library style
    private var appsGridTab: some View {
        VStack(spacing: 10) {
            // Search field
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

            // Icon grid
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 106, maximum: 124), spacing: 4)],
                    spacing: 8
                ) {
                    ForEach(filteredApps.prefix(120)) { app in
                        appIconCell(app)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: .infinity)
        }
    }

    private func appIconCell(_ app: AvailableApp) -> some View {
        let added = selectedApps.contains { $0.id == app.id }
        let blocked = !added && layoutIsFull
        let clashes = !added && !blocked && clashingCandidateIDs.contains(app.id)
        return Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                if added {
                    selectedApps.removeAll { $0.id == app.id }
                    if primaryAppID == app.id { primaryAppID = selectedApps.first?.id }
                } else {
                    let entry = AppGroupEntry(id: app.id, appName: app.name, bundleID: app.id, path: app.path)
                    selectedApps.append(entry)
                    if primaryAppID == nil { primaryAppID = entry.id }
                }
            }
        } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    AppGroupAppIcon(path: app.path, name: app.name, size: 68)
                        .scaleEffect(added ? 0.90 : 1.0)
                        .animation(.spring(response: 0.2), value: added)

                    if added {
                        ZStack {
                            Circle().fill(Color.accentColor).frame(width: 20, height: 20)
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                        .offset(x: 6, y: -6)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                }
                Text(app.name)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 104)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(added ? Color.primary.opacity(0.06) : Color.clear)
            )
            .opacity(blocked || clashes ? 0.35 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: blocked || clashes)
        }
        .buttonStyle(.plain)
        .disabled(blocked || clashes)
        .help(blocked ? "This layout fits up to \(layoutCapacity) windows"
              : clashes ? clashHelp(app) : "")
    }

    private func clashHelp(_ app: AvailableApp) -> String {
        if let s = server.knownMinSize(bundleID: app.id) {
            return "\(app.name) needs a window at least \(Int(s.width)) pt wide — it won't fit alongside your current apps in this layout."
        }
        return "Won't fit alongside your current apps in this layout."
    }

    // Links tab
    private var linksTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 14))
                    TextField("https://…", text: $urlInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .onSubmit { addBrowserTab() }
                }
                .padding(.horizontal, 12).padding(.vertical, 11)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
                    urlInput.isEmpty ? Color.primary.opacity(0.10) : Color.accentColor.opacity(0.5), lineWidth: 1.5))

                HStack(spacing: 10) {
                    Text("Open in").font(.system(size: 14)).foregroundStyle(.secondary)
                    Picker("", selection: $browserChoice) {
                        ForEach(BrowserChoice.allCases, id: \.self) { b in
                            HStack { Image(systemName: b.sfSymbol); Text(b.appName) }.tag(b)
                        }
                    }
                    .labelsHidden().frame(width: 120)
                    Spacer()
                    Button("Add Link") { addBrowserTab() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || layoutIsFull)
                        .help(layoutIsFull ? "This layout fits up to \(layoutCapacity) windows" : "")
                }
            }

            if !recentLinks.isEmpty {
                Text("Recents")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 106, maximum: 124), spacing: 4)],
                        spacing: 8
                    ) {
                        ForEach(recentLinks) { item in recentLinkCell(item) }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: .infinity)
            }
        }
    }

    @Namespace private var toggleNamespace

    /// Sliding-capsule toggle — the selected pill glides between segments.
    private var sourceToggle: some View {
        HStack(spacing: 2) {
            ForEach(Array(["Apps", "Links", "Shortcuts"].enumerated()), id: \.offset) { i, title in
                Button {
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) { appsTab = i }
                } label: {
                    Text(title)
                        .font(.system(size: 13, weight: appsTab == i ? .semibold : .medium))
                        .foregroundStyle(appsTab == i ? .white : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background {
                            if appsTab == i {
                                Capsule()
                                    .fill(Color.accentColor)
                                    .matchedGeometryEffect(id: "togglePill", in: toggleNamespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
    }

    /// Loads real site icons for recent links: tries the high-res
    /// apple-touch-icon first, then favicon.ico. Cached per host.
    final class FaviconLoader {
        static let shared = FaviconLoader()
        private let cache = NSCache<NSString, NSImage>()
        private var failedHosts = Set<String>()

        func icon(for urlString: String) async -> NSImage? {
            guard let host = URL(string: urlString)?.host else { return nil }
            if let cached = cache.object(forKey: host as NSString) { return cached }
            guard !failedHosts.contains(host) else { return nil }
            for candidate in ["https://\(host)/apple-touch-icon.png",
                              "https://\(host)/favicon.ico"] {
                guard let url = URL(string: candidate) else { continue }
                guard let (data, response) = try? await URLSession.shared.data(from: url),
                      (response as? HTTPURLResponse)?.statusCode == 200,
                      let image = NSImage(data: data), image.size.width > 4 else { continue }
                cache.setObject(image, forKey: host as NSString)
                return image
            }
            failedHosts.insert(host)
            return nil
        }
    }

    private struct LinkFaviconTile: View {
        let urlString: String
        @State private var favicon: NSImage?

        var body: some View {
            ZStack {
                if let favicon {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(Color.white)
                    Image(nsImage: favicon)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .fill(LinearGradient(colors: [Color.teal, Color.blue.opacity(0.75)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "globe")
                        .font(.system(size: 26, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 68, height: 68)
            .task(id: urlString) {
                if favicon == nil {
                    favicon = await FaviconLoader.shared.icon(for: urlString)
                }
            }
        }
    }

    private func recentLinkCell(_ item: RecentLinkItem) -> some View {
        let added = selectedApps.contains { $0.url == item.url }
        let blocked = !added && layoutIsFull
        let host = URL(string: item.url)?.host?.replacingOccurrences(of: "www.", with: "") ?? item.url
        return Button {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                if added {
                    selectedApps.removeAll { $0.url == item.url }
                    if primaryAppID != nil && !selectedApps.contains(where: { $0.id == primaryAppID }) {
                        primaryAppID = selectedApps.first?.id
                    }
                } else {
                    let bc = BrowserChoice(rawValue: item.browser) ?? .safari
                    let entry = AppGroupEntry(id: UUID().uuidString,
                                              appName: "\(bc.appName) — \(host)",
                                              bundleID: bc.bundleID, path: bc.appPath,
                                              url: item.url, browser: bc.rawValue)
                    selectedApps.append(entry)
                    if primaryAppID == nil { primaryAppID = entry.id }
                }
            }
        } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    LinkFaviconTile(urlString: item.url)
                        .scaleEffect(added ? 0.90 : 1.0)
                        .animation(.spring(response: 0.2), value: added)

                    if added {
                        ZStack {
                            Circle().fill(Color.accentColor).frame(width: 20, height: 20)
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                        .offset(x: 6, y: -6)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                }
                Text(host)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 104)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(added ? Color.primary.opacity(0.06) : Color.clear)
            )
            .opacity(blocked ? 0.35 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(blocked)
        .help(blocked ? "This layout fits up to \(layoutCapacity) windows" : item.url)
    }

    // Shortcuts tab
    private var shortcutsTab: some View {
        VStack(spacing: 10) {
            if server.availableShortcuts.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "bolt.slash").foregroundStyle(.secondary)
                    Text("No Shortcuts found on this Mac.")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                }
                .padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
                    TextField("Search", text: $shortcutSearchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                    if !shortcutSearchText.isEmpty {
                        Button { shortcutSearchText = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).font(.system(size: 12))
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))

                let fsc: [AppleShortcut] = {
                    let q = shortcutSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    return q.isEmpty ? Array(server.availableShortcuts)
                        : server.availableShortcuts.filter { $0.name.lowercased().contains(q) }
                }()
                ScrollView {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 106, maximum: 124), spacing: 4)],
                        spacing: 8
                    ) {
                        ForEach(fsc.prefix(60)) { s in shortcutIconCell(s) }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: .infinity)
            }
        }
        .confirmationDialog(
            "How should \u{201C}\(pendingShortcut?.name ?? "")\u{201D} run?",
            isPresented: Binding(get: { pendingShortcut != nil },
                                 set: { if !$0 { pendingShortcut = nil } }),
            titleVisibility: .visible
        ) {
            Button("Run in the Background") {
                if let s = pendingShortcut { addShortcut(s, mode: .background) }
                pendingShortcut = nil
            }
            .keyboardShortcut(.defaultAction)
            if !layoutIsFull {
                Button("Show as a Window in the Layout") {
                    if let s = pendingShortcut { addShortcut(s, mode: .slot) }
                    pendingShortcut = nil
                }
            }
            Button("Cancel", role: .cancel) { pendingShortcut = nil }
        } message: {
            Text("Window shortcuts take a slot in your layout. Background shortcuts simply run when the Workspace starts.")
        }
    }

    private func shortcutIconCell(_ shortcut: AppleShortcut) -> some View {
        let added = selectedApps.contains { $0.shortcutName == shortcut.name }
        return Button {
            if added {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
                    selectedApps.removeAll { $0.shortcutName == shortcut.name }
                    if primaryAppID != nil && !selectedApps.contains(where: { $0.id == primaryAppID }) {
                        primaryAppID = selectedApps.first?.id
                    }
                }
            } else if layoutIsFull {
                // No window slot available — background is the only option.
                addShortcut(shortcut, mode: .background)
            } else {
                pendingShortcut = shortcut
            }
        } label: {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    Group {
                        if let icon = MacIconImageCache.shared.shortcutsAppIcon() {
                            Image(nsImage: icon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        } else {
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .fill(LinearGradient(colors: [Color.purple, Color.purple.opacity(0.7)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                                .overlay(
                                    Image(systemName: "bolt.fill")
                                        .font(.system(size: 26, weight: .medium))
                                        .foregroundStyle(.white)
                                )
                        }
                    }
                    .frame(width: 68, height: 68)
                    .scaleEffect(added ? 0.90 : 1.0)
                    .animation(.spring(response: 0.2), value: added)

                    if added {
                        ZStack {
                            Circle().fill(Color.accentColor).frame(width: 20, height: 20)
                            Image(systemName: "checkmark")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                        .offset(x: 6, y: -6)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                }
                Text(shortcut.name)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 104)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(added ? Color.primary.opacity(0.06) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private func addShortcut(_ shortcut: AppleShortcut, mode: ShortcutRunMode) {
        let entryID = UUID().uuidString
        var entry = AppGroupEntry(id: entryID, appName: shortcut.name,
                                  bundleID: "com.apple.shortcuts",
                                  path: "__shortcut__\(entryID)", shortcutName: shortcut.name)
        entry.shortcutRunMode = mode
        withAnimation(.spring(response: 0.25, dampingFraction: 0.75)) {
            selectedApps.append(entry)
            if primaryAppID == nil && mode == .slot { primaryAppID = entry.id }
        }
    }

    // Step 3 — Window order (drag to reorder)
    private var stepOrder: some View {
        let visible = selectedApps.indices.filter {
            let e = selectedApps[$0]
            return !(e.isShortcut && e.shortcutRunMode == .background)
        }
        return VStack(alignment: .leading, spacing: 12) {
            if visible.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text("Add apps in the previous step to set their order.")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            } else {
                List {
                    ForEach(Array(visible.enumerated()), id: \.element) { rank, srcIdx in
                        let entry = selectedApps[srcIdx]
                        let isPrimary = entry.id == primaryAppID
                        HStack(spacing: 14) {
                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.tertiary)
                                .frame(width: 16)
                            ZStack {
                                Circle()
                                    .fill(isPrimary ? Color.accentColor : Color.primary.opacity(0.12))
                                    .frame(width: 28, height: 28)
                                Text("\(rank + 1)")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(isPrimary ? .white : .secondary)
                            }
                            AppGroupAppIcon(path: entry.path, name: entry.appName)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.appName.isEmpty ? "(App)" : entry.appName)
                                    .font(.system(size: 15, weight: .medium))
                                    .lineLimit(1)
                                Text(positionLabel(index: rank, layout: layout))
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if isPrimary {
                                Text("Primary")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Color.accentColor, in: Capsule())
                            } else {
                                Button("Set Primary") {
                                    withAnimation(.easeInOut(duration: 0.15)) { primaryAppID = entry.id }
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.primary.opacity(0.06), in: Capsule())
                            }
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(isPrimary ? Color.accentColor.opacity(0.07) : Color(nsColor: .windowBackgroundColor))
                        .listRowSeparatorTint(Color.primary.opacity(0.07))
                    }
                    .onMove { from, to in
                        var visibleApps = visible.map { selectedApps[$0] }
                        visibleApps.move(fromOffsets: from, toOffset: to)
                        let bgApps = selectedApps.filter { e in e.isShortcut && e.shortcutRunMode == .background }
                        selectedApps = visibleApps + bgApps
                    }
                }
                .listStyle(.plain)
                .scrollDisabled(true)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5))
                .frame(height: CGFloat(visible.count) * 62)

                if let (a, b) = hardConflict {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.orange)
                        Text("In this order, \(a) and \(b) don't fit on this screen. Move the wider app to the larger slot.")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .transition(.opacity.combined(with: .move(edge: .top)))
                } else if let issue = slotIssues.first {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.orange)
                        Text("\(issue.appName)'s window is too big for its spot. Drag it to a larger one.")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .transition(.opacity.combined(with: .move(edge: .top)))
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.arrow.down").font(.system(size: 13)).foregroundStyle(.secondary)
                        Text("Drag a row to reorder. The primary window gets the largest slot.")
                            .font(.system(size: 14)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // Step 4 — Settings
    private var stepSettings: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("When stopped").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(AppGroupStopBehavior.allCases, id: \.self) { option in
                        Button { stopBehavior = option } label: {
                            HStack(spacing: 14) {
                                ZStack {
                                    Circle().strokeBorder(stopBehavior == option ? Color.accentColor : Color.primary.opacity(0.22), lineWidth: 1.5).frame(width: 20, height: 20)
                                    if stopBehavior == option { Circle().fill(Color.accentColor).frame(width: 10, height: 10) }
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label).font(.system(size: 15, weight: .medium))
                                    Text(option.description).font(.system(size: 13)).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 16).padding(.vertical, 14)
                            .background(stopBehavior == option ? Color.accentColor.opacity(0.06) : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if option != AppGroupStopBehavior.allCases.last { Divider().padding(.leading, 50) }
                    }
                }
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Shortcut").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                HStack(spacing: 14) {
                    Image(systemName: "command")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keyboard shortcut")
                            .font(.system(size: 15, weight: .medium))
                        Text("Launch this Workspace from anywhere.")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: $hotkeyIndex) {
                        Text("None").tag(Int?.none)
                        ForEach(1...9, id: \.self) { i in
                            if takenHotkeys.contains(i) && i != existing?.hotkeyIndex {
                                Text("⌘ ⌥ \(i) — in use").tag(Int?.some(i))
                            } else {
                                Text("⌘ ⌥ \(i)").tag(Int?.some(i))
                            }
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5))
            }
        }
    }

    /// Measures the true minimum size of every selected app — launching apps
    /// that aren't running so nothing validates on missing data — then runs
    /// the final fit check before saving.
    private func verifyAndSave() {
        isVerifyingFit = true
        Task {
            for entry in selectedApps where !entry.isShortcut {
                _ = await server.measureMinSizeForValidation(entry: entry)
            }
            isVerifyingFit = false
            if hardConflict != nil || !slotIssues.isEmpty || visibleSelectedCount > layoutCapacity {
                showSaveBlocked = true
            } else {
                onSave(makeGroup())
            }
        }
    }

    private var takenHotkeys: Set<Int> {
        Set(server.appGroups.compactMap { $0.id == existing?.id ? nil : $0.hotkeyIndex })
    }

    // MARK: - Navigation footer

    private var navigationFooter: some View {
        HStack(spacing: 10) {
            Button("Cancel") { dismiss() }
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)

            if existing != nil, let onDelete {
                Button(role: .destructive) { showDeleteConfirm = true } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.red)
                }
                .controlSize(.large)
                .help("Delete Workspace")
                .confirmationDialog("Delete \"\(name.isEmpty ? "this workspace" : name)\"?",
                                    isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                    Button("Delete Workspace", role: .destructive) { dismiss(); onDelete() }
                    Button("Cancel", role: .cancel) {}
                } message: { Text("This cannot be undone.") }
            }

            Spacer()

            if currentStep > 0 {
                Button("Back") {
                    stepForward = false
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { currentStep -= 1 }
                }
                .controlSize(.large)
            }
            if isLastStep {
                Button {
                    verifyAndSave()
                } label: {
                    if isVerifyingFit {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Checking window sizes…")
                        }
                    } else {
                        Text("Save Workspace")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!isValid || isVerifyingFit)
                .keyboardShortcut(.defaultAction)
                .alert("This Workspace can't be saved yet", isPresented: $showSaveBlocked) {
                    Button("Review Layout") {
                        stepForward = false
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { currentStep = 1 }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Some windows don't fit the chosen layout on this screen. Adjust the layout, apps, or window order first.")
                }
            } else {
                Button("Continue") {
                    stepForward = true
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { currentStep += 1 }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canAdvance)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    // MARK: - Row helpers

    @ViewBuilder
    private func selectedAppRow(_ entry: AppGroupEntry) -> some View {
        HStack(spacing: 10) {
            AppGroupAppIcon(path: entry.path, name: entry.appName)
            Text(entry.appName).font(.system(size: 14)).lineLimit(1)
            Spacer()
            if entry.id == primaryAppID {
                Text("Primary").font(.system(size: 11, weight: .semibold)).foregroundStyle(.blue)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    selectedApps.removeAll { $0.id == entry.id }
                    if primaryAppID == entry.id { primaryAppID = selectedApps.first?.id }
                }
            } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.red.opacity(0.8)).font(.system(size: 16))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 5).padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture { primaryAppID = entry.id }
    }

    @ViewBuilder
    private func availableAppRow(_ app: AvailableApp) -> some View {
        let added = selectedApps.contains { $0.id == app.id }
        HStack(spacing: 10) {
            AppGroupAppIcon(path: app.path, name: app.name)
            Text(app.name).font(.system(size: 14)).lineLimit(1)
            Spacer()
            if added { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor).font(.system(size: 16)) }
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(added ? Color.accentColor.opacity(0.07) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                if added {
                    selectedApps.removeAll { $0.id == app.id }
                    if primaryAppID == app.id { primaryAppID = selectedApps.first?.id }
                } else {
                    let entry = AppGroupEntry(id: app.id, appName: app.name, bundleID: app.id, path: app.path)
                    selectedApps.append(entry)
                    if primaryAppID == nil { primaryAppID = entry.id }
                }
            }
        }
    }

    @ViewBuilder
    private func availableShortcutRow(_ shortcut: AppleShortcut) -> some View {
        let added = selectedApps.contains { $0.shortcutName == shortcut.name }
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.purple.opacity(added ? 0.25 : 0.12))
                Image(systemName: "bolt.fill").font(.system(size: 10, weight: .medium)).foregroundStyle(Color.purple)
            }
            .frame(width: 26, height: 26)
            Text(shortcut.name).font(.system(size: 14)).lineLimit(1)
            Spacer()
            if added { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor).font(.system(size: 16)) }
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(added ? Color.accentColor.opacity(0.07) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                if added {
                    selectedApps.removeAll { $0.shortcutName == shortcut.name }
                    if primaryAppID != nil && !selectedApps.contains(where: { $0.id == primaryAppID }) {
                        primaryAppID = selectedApps.first?.id
                    }
                } else {
                    let entryID = UUID().uuidString
                    var entry = AppGroupEntry(id: entryID, appName: shortcut.name,
                                              bundleID: "com.apple.shortcuts",
                                              path: "__shortcut__\(entryID)", shortcutName: shortcut.name)
                    entry.shortcutRunMode = .background
                    selectedApps.append(entry)
                    if primaryAppID == nil { primaryAppID = entry.id }
                }
            }
        }
    }

    private func addBrowserTab() {
        var raw = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !layoutIsFull else { return }
        if !raw.lowercased().hasPrefix("http://") && !raw.lowercased().hasPrefix("https://") { raw = "https://" + raw }
        let displayName = URL(string: raw)?.host ?? raw
        let entry = AppGroupEntry(id: UUID().uuidString,
                                  appName: "\(browserChoice.appName) — \(displayName)",
                                  bundleID: browserChoice.bundleID, path: browserChoice.appPath,
                                  url: raw, browser: browserChoice.rawValue)
        withAnimation(.easeInOut(duration: 0.15)) {
            selectedApps.append(entry)
            if primaryAppID == nil { primaryAppID = entry.id }
        }
        rememberRecentLink(url: raw, browser: browserChoice.rawValue)
        urlInput = ""
    }

    // MARK: - Recent links

    private func loadRecentLinks() {
        var items: [RecentLinkItem] = []
        if let data = UserDefaults.standard.data(forKey: "rw_recent_links"),
           let decoded = try? JSONDecoder().decode([RecentLinkItem].self, from: data) {
            items = decoded
        }
        // Seed with links already used in other Workspaces.
        for group in server.appGroups {
            for e in group.apps {
                guard let url = e.url, !items.contains(where: { $0.url == url }) else { continue }
                items.append(RecentLinkItem(url: url, browser: e.browser ?? BrowserChoice.safari.rawValue))
            }
        }
        recentLinks = Array(items.prefix(12))
    }

    private func rememberRecentLink(url: String, browser: String) {
        var items = recentLinks.filter { $0.url != url }
        items.insert(RecentLinkItem(url: url, browser: browser), at: 0)
        recentLinks = Array(items.prefix(12))
        if let data = try? JSONEncoder().encode(recentLinks) {
            UserDefaults.standard.set(data, forKey: "rw_recent_links")
        }
    }

    private func positionLabel(index: Int, layout: AppGroupLayout) -> String {
        switch layout {
        case .split1x1:  return index == 0 ? "Left" : "Right"
        case .split1x1v: return index == 0 ? "Top" : "Bottom"
        case .split1x2:  return index == 0 ? "Left (large)" : index == 1 ? "Right top" : "Right bottom"
        case .split2x1:  return index == 0 ? "Right (large)" : index == 1 ? "Left top" : "Left bottom"
        case .split1x2h: return index == 0 ? "Top (large)" : index == 1 ? "Bottom left" : "Bottom right"
        case .grid2x2:   return ["Top left","Top right","Bottom left","Bottom right"][min(index, 3)]
        }
    }

    private func makeGroup() -> AppGroup {
        AppGroup(id: existing?.id ?? UUID().uuidString,
                 name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                 icon: icon.trimmingCharacters(in: .whitespacesAndNewlines),
                 apps: selectedApps, layout: layout,
                 primaryAppID: primaryAppID ?? selectedApps.first?.id,
                 stopBehavior: stopBehavior,
                 createdAt: existing?.createdAt ?? Date(),
                 hotkeyIndex: hotkeyIndex)
    }
}

struct AppGroupAppIcon: View {
    let path: String
    let name: String
    var size: CGFloat = 26
    @State private var img: NSImage?

    var body: some View {
        Group {
            if let img {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "app")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .font(.system(size: size * 0.55))
            }
        }
        .frame(width: size, height: size)
        .task(id: path) {
            let loaded = await Task.detached(priority: .userInitiated) {
                MacIconImageCache.shared.image(forAppPath: path)
            }.value
            img = loaded
        }
    }
}


// MARK: - Reconnecting screen (shown when a previously trusted device is offline)

struct MacReconnectingView: View {
    let deviceName: String
    let pin: String
    @StateObject private var server = RewindpadServer.shared
    @State private var showPairNew = false

    var body: some View {
        ZStack {
            MacLiquidBackground()

            VStack(spacing: 0) {
                Spacer()

                // Spinner + icon
                ZStack {
                    Circle()
                        .stroke(Color.primary.opacity(0.08), lineWidth: 3)
                        .frame(width: 80, height: 80)
                    Image(systemName: "iphone.radiowaves.left.and.right")
                        .font(.system(size: 32, weight: .light))
                        .foregroundStyle(Color.primary.opacity(0.35))
                }
                .padding(.bottom, 28)

                Text("Waiting for \(deviceName)")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("Open Rewindpad on your iPhone to reconnect.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .padding(.top, 8)

                Spacer()

                // Escape hatch — pair a different device
                if showPairNew {
                    MacQRConnectView(pin: pin)
                        .frame(maxWidth: 480)
                        .padding(.bottom, 24)
                } else {
                    Button("Connect a different device…") {
                        withAnimation { showPairNew = true }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 32)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - QR / PIN connect screen

struct MacQRConnectView: View {
    let pin: String

    private let appStoreURL = "itms-apps://apps.apple.com/app/id0000000000"

    var body: some View {
        ZStack {
            MacLiquidBackground()

            VStack(spacing: 26) {
                VStack(spacing: 12) {
                    Text("Launchpad")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.primary)

                    Text("Connect your iPhone and jump straight into your Launchpad editor.")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 22) {
                    Image(nsImage: MacQRCodeImage.make(from: appStoreURL))
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 240, height: 240)
                        .padding(22)
                        .background(
                            LinearGradient(
                                colors: [Color.white.opacity(0.98), Color.white.opacity(0.92)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: RoundedRectangle(cornerRadius: 30, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 30, style: .continuous)
                                .stroke(Color.white.opacity(0.72), lineWidth: 1)
                        }
                        .shadow(color: .black.opacity(0.06), radius: 18, y: 8)
                        .accessibilityLabel("QR code to open Launchpad in the App Store")

                    VStack(spacing: 8) {
                        Text("Scan with your iPhone to get Launchpad.")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.center)

                        Text("Already installed? Open Launchpad on your iPhone and enter this PIN.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    VStack(spacing: 8) {
                        Text("PAIRING PIN")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .tracking(1.8)

                        Text(pin)
                            .font(.system(size: 68, weight: .black, design: .monospaced))
                            .foregroundStyle(.primary)
                            .monospacedDigit()
                            .kerning(3)
                            .padding(.top, 2)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Pairing PIN \(pin)")
                }
                .padding(.horizontal, 34)
                .padding(.vertical, 34)
                .frame(maxWidth: 540)
                .background {
                    MacNativeWindowMaterial(cornerRadius: 34)
                }
            }
            .padding(40)
        }
    }
}

enum MacQRCodeImage {
    static func make(from string: String) -> NSImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 14, y: 14)) else {
            return NSImage(size: NSSize(width: 240, height: 240))
        }

        let representation = NSCIImageRep(ciImage: outputImage)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}

struct ContentView: View {
    @StateObject private var server = RewindpadServer.shared
    @State private var selectedTab: MacSidebarTab? = .bar
    /// Persisted — user can collapse the iPhone pairing section; it stays hidden across relaunches.
    @AppStorage("rw_show_pairing_panel") private var showPairingPanel: Bool = true

    // Mac app always runs — no sheet, no gate, no waiting for iPhone.
    var body: some View {
        editorView
            .frame(minWidth: 1180, minHeight: 760)
            .background(MacLiquidBackground())
            .onReceive(NotificationCenter.default.publisher(for: .openScenesTab)) { _ in
                selectedTab = .groups
            }
            .onReceive(NotificationCenter.default.publisher(for: .openWorkspaceCreator)) { _ in
                // Menu bar CTA: land on the Workspaces tab; the view itself
                // opens the creator modal from the pending flag.
                selectedTab = .groups
            }
    }

    private var editorView: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            Group {
                switch selectedTab ?? .bar {
                case .bar:
                    BarMacView(server: server)
                case .groups:
                    AppGroupsManagementView(server: server)
                case .about:
                    AboutMacView(server: server)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(MacLiquidBackground())
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selectedTab) {
                Section {
                    Label {
                        Text("Launchpad")
                    } icon: {
                        Image("LaunchpadIcon")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16, height: 16)
                    }
                    .tag(MacSidebarTab.bar)
                    Label {
                        Text("Workspace")
                    } icon: {
                        Image("WorkspaceIcon")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16, height: 16)
                    }
                    .tag(MacSidebarTab.groups)
                    Label {
                        Text("About")
                    } icon: {
                        Image("AboutIcon")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16, height: 16)
                    }
                    .tag(MacSidebarTab.about)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .padding(.top, 10)

            Spacer(minLength: 0)
            connectionCard
        }
        .frame(minWidth: 220, idealWidth: 230, maxWidth: 240)
        .background {
            MacNativeWindowMaterial()
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.white.opacity(0.25))
                .frame(width: 1)
        }
    }

    private var connectionCard: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── iPhone companion ────────────────────────────────────────
            if server.isConnected {
                // iPhone connected — show name, no PIN needed
                HStack(spacing: 8) {
                    ZStack {
                        Circle().fill(Color.green.opacity(0.15)).frame(width: 22, height: 22)
                        Image(systemName: "iphone")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.green)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(server.connectedDeviceName ?? server.lastKnownDeviceName ?? "iPhone")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text("Companion connected")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

            } else {
                // iPhone not connected — collapsible PIN section
                VStack(alignment: .leading, spacing: 0) {

                    // Row: companion label + toggle button
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.secondary.opacity(0.3))
                            .frame(width: 7, height: 7)
                        Text(server.lastKnownDeviceName.map { "\($0) · Offline" }
                             ?? "iPhone companion")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        // Toggle PIN visibility
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showPairingPanel.toggle()
                            }
                        } label: {
                            Image(systemName: showPairingPanel ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                    // Pairing — bento tiles: QR tile + code tile + hint
                    if showPairingPanel {
                        VStack(spacing: 8) {
                            // QR tile
                            VStack {
                                Image(nsImage: MacQRCodeImage.make(from: server.pin))
                                    .interpolation(.none)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 92, height: 92)
                                    .padding(9)
                                    .background(Color.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    .accessibilityLabel("QR code for pairing")
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                            // Code tile
                            VStack(spacing: 2) {
                                Text(server.pin)
                                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                                    .kerning(7)
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                                Text("Pairing code")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                            Text("Open Rewindpad on your iPhone and scan, or type the code.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 6)
                                .padding(.top, 4)
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                        .padding(.bottom, 16)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.2), value: server.isConnected)
        .padding(.bottom, 4)
    }
}

enum MacSidebarTab: Hashable {
    case bar
    case groups
    case about
}

struct MacNativeWindowMaterial: NSViewRepresentable {
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .windowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = cornerRadius > 0
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = .windowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = cornerRadius > 0
    }
}

struct MacSlotSelection: Identifiable {
    let pageIndex: Int
    let slotIndex: Int
    let rows: Int

    var id: String { "\(pageIndex)-\(slotIndex)-\(rows)" }
}


struct MacLaunchpadPageOffsetPreferenceKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]

    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { _, newValue in newValue }
    }
}

struct BarMacView: View {
    @ObservedObject var server: RewindpadServer
    @State private var currentPage = 0
    @State private var activeSlot: MacSlotSelection?
    @State private var editingIconShortcut: SavedShortcut?
    @State private var draggingShortcutID: String?

    private let columns = 2
    private let fixedRows = 4
    private let slotsPerPage = 8
    private let gridSpacing: CGFloat = 10
    private let pageSpacing: CGFloat = 14
    private let previewPadding: CGFloat = 8
    private let compactGridWidth: CGFloat = 340
    private let squareTileHeight: CGFloat = 118
    private let trailingEmptySlots = 8

    private var visiblePreviewHeight: CGFloat {
        let fourRows = (squareTileHeight * 4) + (gridSpacing * 3)
        let peekRow = squareTileHeight * 0.42
        return fourRows + peekRow + (previewPadding * 2)
    }

    private var pageCount: Int {
        let highestPlacedIndex = server.shortcuts
            .compactMap { item -> Int? in
                guard item.pageIndex != nil || item.slotIndex != nil else {
                    return nil
                }

                return continuousIndex(for: item)
            }
            .max() ?? 0

        let neededForPlacedItems = (highestPlacedIndex / slotsPerPage) + 1
        let neededForEmptyDropTargets = max(1, Int(ceil(Double(server.shortcuts.count + trailingEmptySlots) / Double(slotsPerPage))))

        return max(1, max(neededForPlacedItems, neededForEmptyDropTargets))
    }

    private var visibleSlotCount: Int {
        pageCount * slotsPerPage
    }

    private var orderedShortcuts: [SavedShortcut] {
        server.shortcuts.sorted { first, second in
            let firstIndex = continuousIndex(for: first)
            let secondIndex = continuousIndex(for: second)

            if firstIndex != secondIndex {
                return firstIndex < secondIndex
            }

            return first.createdAt < second.createdAt
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(Color.primary.opacity(0.14))
                .frame(height: 1)

            VStack(spacing: 6) {
                HStack(spacing: 6) {
                    iphonePreview
                    pageIndicator
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 0)
        .padding(.bottom, 18)
        .sheet(item: $activeSlot) { slot in
            AddBarItemSheet(server: server, slot: slot) {
                activeSlot = nil
                normalizePageLayout()
            }
            .frame(width: 640, height: 560)
        }
        .sheet(item: $editingIconShortcut) { shortcut in
            MacIconChoiceSheet(
                title: "Edit Icon",
                subtitle: shortcut.title,
                defaultLabel: "Keep Default",
                defaultIcon: SavedShortcut(id: "icon.default", title: shortcut.title, type: shortcut.type, target: shortcut.target, icon: shortcut.icon, iconData: nil, createdAt: Date()),
                onDefault: {
                    updateIcon(for: shortcut, iconData: nil)
                    editingIconShortcut = nil
                },
                onIconData: { iconData in
                    updateIcon(for: shortcut, iconData: iconData)
                    editingIconShortcut = nil
                },
                onCancel: {
                    editingIconShortcut = nil
                }
            )
            .frame(width: 430, height: 360)
        }
        .onAppear {
            DispatchQueue.main.async {
                restoreCustomIconsFromPersistentDisk()
                syncFixedLayoutToServer()
                normalizePageLayout()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Launchpad")
                .font(.title.weight(.bold))
            Text("Arrange your iPhone home screen from your Mac.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 24)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }



    private var iphonePreview: some View {
        ZStack {
            MacNativeWindowMaterial(cornerRadius: 34)

            GeometryReader { geometry in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: pageSpacing) {
                        ForEach(0..<pageCount, id: \.self) { page in
                            pageSection(page: page)
                                .background(
                                    GeometryReader { pageGeometry in
                                        Color.clear.preference(
                                            key: MacLaunchpadPageOffsetPreferenceKey.self,
                                            value: [page: pageGeometry.frame(in: .named("macLaunchpadScroll")).minY]
                                        )
                                    }
                                )
                        }
                    }
                    .frame(width: compactContentWidth(in: geometry.size), alignment: .top)
                    .padding(.vertical, previewPadding)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
                .coordinateSpace(name: "macLaunchpadScroll")
                .scrollIndicators(.hidden)
                .mask(outerScrollFadeMask)
                .onPreferenceChange(MacLaunchpadPageOffsetPreferenceKey.self) { values in
                    updateCurrentPage(from: values)
                }
            }
        }
        .frame(height: visiblePreviewHeight)
        .frame(maxWidth: 760)
        .accessibilityLabel("Launchpad preview. Scroll vertically through pages.")
    }

    private var gridColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: gridSpacing),
            GridItem(.flexible(), spacing: gridSpacing)
        ]
    }

    private func compactContentWidth(in size: CGSize) -> CGFloat {
        min(compactGridWidth, max(300, size.width - (previewPadding * 2)))
    }

    private var outerScrollFadeMask: some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0.00),
                .init(color: .black, location: 0.76),
                .init(color: .black.opacity(0.72), location: 0.88),
                .init(color: .clear, location: 1.00)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func pageSection(page: Int) -> some View {
        LazyVGrid(columns: gridColumns, spacing: gridSpacing) {
            ForEach(0..<slotsPerPage, id: \.self) { slot in
                pageSlot(page: page, slot: slot)
            }
        }
    }

    @ViewBuilder
    private func pageSlot(page: Int, slot: Int) -> some View {
        if let shortcut = shortcutAt(page: page, slot: slot) {
            MacPreviewFilledSlot(
                shortcut: shortcut,
                isDragging: draggingShortcutID == shortcut.id,
                onRemove: {
                    remove(shortcut)
                },
                onEditIcon: {
                    editingIconShortcut = shortcut
                }
            )
            .scaleEffect(draggingShortcutID == shortcut.id ? 1.035 : 1.0)
            .shadow(
                color: Color.black.opacity(draggingShortcutID == shortcut.id ? 0.24 : 0.08),
                radius: draggingShortcutID == shortcut.id ? 18 : 8,
                x: 0,
                y: draggingShortcutID == shortcut.id ? 10 : 3
            )
            .zIndex(draggingShortcutID == shortcut.id ? 10 : 0)
            .animation(.spring(response: 0.24, dampingFraction: 0.78), value: draggingShortcutID)
            .frame(height: squareTileHeight)
            .onTapGesture {
                activeSlot = MacSlotSelection(pageIndex: page, slotIndex: slot, rows: fixedRows)
            }
            .onDrag {
                draggingShortcutID = shortcut.id
                return NSItemProvider(object: shortcut.id as NSString)
            }
            .onDrop(of: [UTType.text], isTargeted: nil) { _ in
                moveDraggedShortcut(toPage: page, slot: slot)
            }
        } else {
            MacPreviewEmptySlot {
                activeSlot = MacSlotSelection(pageIndex: page, slotIndex: slot, rows: fixedRows)
            }
            .frame(height: squareTileHeight)
            .onDrop(of: [UTType.text], isTargeted: nil) { _ in
                moveDraggedShortcut(toPage: page, slot: slot)
            }
        }
    }



    private var pageIndicator: some View {
        VStack(spacing: 9) {
            ForEach(0..<pageCount, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(index == currentPage ? Color.accentColor : Color.secondary.opacity(0.22))
                    .frame(width: 7, height: index == currentPage ? 28 : 7)
                    .overlay {
                        Capsule(style: .continuous)
                            .stroke(Color.white.opacity(index == currentPage ? 0.28 : 0.10), lineWidth: 1)
                    }
                    .animation(.snappy(duration: 0.18), value: currentPage)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 6)
        .background(.regularMaterial, in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .frame(width: 28)
        .frame(maxHeight: .infinity, alignment: .center)
        .accessibilityLabel("Page \(currentPage + 1) of \(pageCount)")
    }

    private func updateCurrentPage(from offsets: [Int: CGFloat]) {
        guard let nearest = offsets.min(by: { abs($0.value) < abs($1.value) })?.key else {
            return
        }

        let nextPage = min(max(nearest, 0), max(pageCount - 1, 0))

        guard nextPage != currentPage else {
            return
        }

        withAnimation(.snappy(duration: 0.18)) {
            currentPage = nextPage
        }
    }

    private func shortcutAt(page: Int, slot: Int) -> SavedShortcut? {
        server.shortcuts.first { item in
            item.pageIndex == page && item.slotIndex == slot
        }
    }

    private func continuousIndex(for item: SavedShortcut) -> Int {
        let page = max(item.pageIndex ?? 0, 0)
        let slot = max(item.slotIndex ?? 0, 0)

        return (page * slotsPerPage) + slot
    }

    private func payload(forPage page: Int, slot: Int) -> (page: Int, slot: Int) {
        (page, slot)
    }

    private func moveDraggedShortcut(toPage targetPage: Int, slot targetSlot: Int) -> Bool {
        guard let draggedID = draggingShortcutID,
              let draggedIndex = server.shortcuts.firstIndex(where: { $0.id == draggedID }) else {
            return false
        }

        let draggedItem = server.shortcuts[draggedIndex]
        let sourcePage = draggedItem.pageIndex ?? 0
        let sourceSlot = draggedItem.slotIndex ?? 0
        let targetItem = shortcutAt(page: targetPage, slot: targetSlot)

        if targetItem?.id == draggedItem.id {
            draggingShortcutID = nil
            return true
        }

        withAnimation(.snappy(duration: 0.18)) {
            server.shortcuts[draggedIndex] = draggedItem.copyForBarSlot(
                pageIndex: targetPage,
                slotIndex: targetSlot,
                pageRows: fixedRows
            )

            if let targetItem,
               let targetItemIndex = server.shortcuts.firstIndex(where: { $0.id == targetItem.id }) {
                server.shortcuts[targetItemIndex] = targetItem.copyForBarSlot(
                    pageIndex: sourcePage,
                    slotIndex: sourceSlot,
                    pageRows: fixedRows
                )
            }
        }

        draggingShortcutID = nil
        persistAndPush()
        return true
    }



    private func restoreCustomIconsFromPersistentDisk() {
        var didChange = false

        for index in server.shortcuts.indices {
            let item = server.shortcuts[index]

            guard item.type == "shortcut" || item.type == "link",
                  let value = item.iconData,
                  !value.isEmpty else {
                continue
            }

            if MacPersistentIconStore.isPersistentReference(value) {
                continue
            }

            guard let persistentReference = MacPersistentIconStore.saveBase64Immediately(value) else {
                continue
            }

            server.shortcuts[index] = item.withIconData(persistentReference)
            didChange = true
        }

        if didChange {
            syncFixedLayoutToServer()
            server.shortcuts = server.shortcuts.map(barSlotPayloadSafeShortcut)

            DispatchQueue.global(qos: .utility).async {
                RewindpadShortcutDiskStore.save(server.shortcuts)
            }
        }
    }

    private func updateIcon(for item: SavedShortcut, iconData: String?) {
        DispatchQueue.main.async {
            guard let index = server.shortcuts.firstIndex(where: { $0.id == item.id }) else {
                return
            }

            let updated = SavedShortcut(
                id: server.shortcuts[index].id,
                title: server.shortcuts[index].title,
                type: server.shortcuts[index].type,
                target: server.shortcuts[index].target,
                icon: server.shortcuts[index].icon,
                iconData: MacPersistentIconStore.persistentReference(for: iconData),
                createdAt: server.shortcuts[index].createdAt,
                pageIndex: server.shortcuts[index].pageIndex,
                slotIndex: server.shortcuts[index].slotIndex,
                pageRows: fixedRows
            )

            server.shortcuts[index] = barSlotPayloadSafeShortcut(updated)
            server.pushLaunchpadDeltaUpsert(server.shortcuts[index])

            DispatchQueue.global(qos: .utility).async {
                RewindpadShortcutDiskStore.save(server.shortcuts)
            }
        }
    }

    private func remove(_ item: SavedShortcut) {
        DispatchQueue.main.async {
            server.shortcuts.removeAll { existing in
                existing.id == item.id || (existing.type == item.type && existing.target == item.target)
            }

            syncFixedLayoutToServer()
            server.shortcuts = server.shortcuts.map(barSlotPayloadSafeShortcut)
            server.pushLaunchpadDeltaRemove(item)

            DispatchQueue.global(qos: .utility).async {
                RewindpadShortcutDiskStore.save(server.shortcuts)
            }
        }
    }



    private func normalizePageLayout() {
        var changed = false

        for index in server.shortcuts.indices {
            var item = server.shortcuts[index]

            guard item.pageIndex == nil || item.slotIndex == nil else {
                if item.pageRows != fixedRows {
                    server.shortcuts[index] = item.copyForBarSlot(
                        pageIndex: item.pageIndex ?? 0,
                        slotIndex: item.slotIndex ?? 0,
                        pageRows: fixedRows
                    )
                    changed = true
                }

                continue
            }

            let openSlot = firstOpenSlot()
            item = item.copyForBarSlot(
                pageIndex: openSlot.page,
                slotIndex: openSlot.slot,
                pageRows: fixedRows
            )
            server.shortcuts[index] = item
            changed = true
        }

        if changed {
            syncFixedLayoutToServer()
            server.shortcuts = server.shortcuts.map(barSlotPayloadSafeShortcut)
            server.pushLaunchpadDeltaSnapshot()

            DispatchQueue.global(qos: .utility).async {
                RewindpadShortcutDiskStore.save(server.shortcuts)
            }
        }
    }



    private func firstOpenSlot() -> (page: Int, slot: Int) {
        var page = 0

        while page < max(pageCount + 1, 1_000) {
            for slot in 0..<slotsPerPage {
                if shortcutAt(page: page, slot: slot) == nil {
                    return (page, slot)
                }
            }

            page += 1
        }

        return (0, 0)
    }

    private func syncFixedLayoutToServer() {
        let maxNeededPage = max(0, pageCount - 1)
        let nextRows = (0...maxNeededPage).reduce(into: [String: Int]()) { result, page in
            result[String(page)] = fixedRows
        }

        if server.barPageRows != nextRows {
            server.barPageRows = nextRows
        }
    }

    private func persistAndPush() {
        syncFixedLayoutToServer()
        server.shortcuts = server.shortcuts.map(barSlotPayloadSafeShortcut)

        // Push first, save after. iPhone should not wait on disk I/O.
        server.pushLaunchpadDeltaSnapshot()

        DispatchQueue.global(qos: .utility).async {
            RewindpadShortcutDiskStore.save(server.shortcuts)
        }
    }

    private func barSlotPayloadSafeShortcut(_ item: SavedShortcut) -> SavedShortcut {
        let iconData: String?
        if item.type == "shortcut" || item.type == "link" {
            iconData = MacPersistentIconStore.persistentReference(for: item.iconData)
        } else {
            iconData = nil
        }

        return SavedShortcut(
            id: item.id,
            title: item.title,
            type: item.type,
            target: item.target,
            icon: item.icon,
            iconData: iconData,
            createdAt: item.createdAt,
            pageIndex: item.pageIndex,
            slotIndex: item.slotIndex,
            pageRows: fixedRows
        )
    }


}










extension SavedShortcut {
    func copyForBarSlot(pageIndex: Int, slotIndex: Int, pageRows: Int) -> SavedShortcut {
        SavedShortcut(
            id: id,
            title: title,
            type: type,
            target: target,
            icon: icon,
            iconData: iconData,
            createdAt: createdAt,
            pageIndex: pageIndex,
            slotIndex: slotIndex,
            pageRows: pageRows
        )
    }
}

struct MacPreviewFilledSlot: View {
    let shortcut: SavedShortcut
    var isDragging: Bool = false
    let onRemove: () -> Void
    let onEditIcon: () -> Void
    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 9) {
                ZStack(alignment: .bottomTrailing) {
                    MacBarIcon(shortcut: shortcut, size: 72)

                    if shortcut.type == "link" {
                        MacLinkSlotBadge(size: 72)
                            .offset(x: -4, y: -4)
                            .allowsHitTesting(false)
                    }
                }
                .frame(width: 72, height: 72)
                .shadow(color: .black.opacity(isHovered ? 0.08 : 0.04), radius: isHovered ? 10 : 5, y: 3)

                Text(displayTitle(shortcut.title))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity)
            }
            .padding(8)
            .frame(minHeight: 96)
            .frame(maxWidth: .infinity)
            .opacity(isDragging ? 0.45 : 1)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.10) : Color.primary.opacity(0.06))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isDragging ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 2)
            }

            if isHovered {
                Button(action: onRemove) {
                    ZStack {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 22, height: 22)

                        Image(systemName: "minus")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
                .transition(.opacity.combined(with: .scale))
                .accessibilityLabel("Remove \(shortcut.title)")
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contextMenu {
            Button("Edit Icon") {
                onEditIcon()
            }

            Divider()

            Button("Remove", role: .destructive) {
                onRemove()
            }
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    private func displayTitle(_ title: String) -> String {
        let words = title.split(separator: " ")
        guard words.count > 3 else { return title }
        return words.prefix(3).joined(separator: " ") + "…"
    }
}

struct MacPreviewEmptySlot: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(isHovered ? Color.primary.opacity(0.04) : Color.clear)
                        .frame(width: 72, height: 72)
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.secondary.opacity(isHovered ? 0.34 : 0.22), style: StrokeStyle(lineWidth: 1, dash: [5, 5]))
                        }

                    Circle()
                        .fill(isHovered ? Color.accentColor : Color.accentColor.opacity(0.16))
                        .frame(width: isHovered ? 38 : 34, height: isHovered ? 38 : 34)
                        .overlay {
                            Image(systemName: "plus")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(isHovered ? .white : Color.accentColor)
                        }
                }

                Text(isHovered ? "Add" : "Empty")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(isHovered ? .primary : .secondary)
            }
            .padding(8)
            .frame(minHeight: 96)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.03) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

struct MacBarIcon: View {
    let shortcut: SavedShortcut
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(background)
                .frame(width: size, height: size)
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                }

            if let nsImage = decodedImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: size * imageScale, height: size * imageScale)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
            } else {
                Image(systemName: fallbackSystemImage)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(fallbackTint)
            }
        }
    }

    private var decodedImage: NSImage? {
        switch shortcut.type {
        case "app":
            return MacIconImageCache.shared.image(forAppPath: shortcut.target)
        case "shortcut":
            return MacIconImageCache.shared.image(forBase64: shortcut.iconData) ?? MacIconImageCache.shared.shortcutsAppIcon()
        default:
            return MacIconImageCache.shared.image(forBase64: shortcut.iconData)
        }
    }

    private var imageScale: CGFloat { shortcut.type == "link" ? 0.64 : 0.82 }
    private var background: Color { shortcut.type == "link" ? .white : Color(nsColor: .windowBackgroundColor) }

    private var fallbackSystemImage: String {
        switch shortcut.type {
        case "link": return "link"
        case "shortcut": return "sparkles"
        case "command": return shortcut.icon
        default: return "app.fill"
        }
    }

    private var fallbackTint: Color {
        switch shortcut.type {
        case "link": return .blue
        case "shortcut": return .purple
        default: return .accentColor
        }
    }
}



struct MacLinkSlotBadge: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(.regularMaterial)
                .frame(width: size * 0.22, height: size * 0.22)
                .overlay {
                    Circle()
                        .stroke(Color.primary.opacity(0.10), lineWidth: 0.6)
                }
                .shadow(color: .black.opacity(0.06), radius: 1.5, x: 0, y: 0.8)

            Image(systemName: "link")
                .font(.system(size: size * 0.095, weight: .bold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
        }
    }
}




extension SavedShortcut {
    func withIconData(_ iconData: String?) -> SavedShortcut {
        SavedShortcut(
            id: id,
            title: title,
            type: type,
            target: target,
            icon: icon,
            iconData: iconData,
            createdAt: createdAt,
            pageIndex: pageIndex,
            slotIndex: slotIndex,
            pageRows: pageRows
        )
    }
}

enum AddBarMode: String, CaseIterable, Identifiable {
    case app = "App"
    case shortcuts = "Apple Shortcuts"
    case links = "Website Links"
    var id: String { rawValue }
}

struct AddBarItemSheet: View {
    @ObservedObject var server: RewindpadServer
    let slot: MacSlotSelection
    let onClose: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var mode: AddBarMode = .app
    @State private var search = ""
    @State private var linkTitle = ""
    @State private var linkURL = ""
    @State private var isFetchingLinkFavicon = false
    @State private var lastFetchedLogoURL = ""
    @State private var cachedWebsiteIconData: String?
    @State private var pendingIconItem: SavedShortcut?

    private var filteredShortcuts: [AppleShortcut] {
        let items = server.availableShortcuts.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return items }
        return items.filter { $0.name.range(of: search, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    private var filteredApps: [AvailableApp] {
        let items = server.availableApps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        guard !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return items }
        return items.filter { $0.name.range(of: search, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    var body: some View {
        VStack(spacing: 18) {
            topBar

            switch mode {
            case .app:
                appContent
            case .shortcuts:
                shortcutContent
            case .links:
                linkContent
            }
        }
        .padding(28)
        .background(MacLiquidBackground())
        .sheet(item: $pendingIconItem) { item in
            MacIconChoiceSheet(
                title: item.type == "shortcut" ? "Choose Shortcut Icon" : "Choose Link Icon",
                subtitle: item.type == "shortcut" ? "\(item.title) needs an emoji or image before it can be added." : "Choose how this link should look.",
                defaultLabel: "Keep Default",
                defaultIcon: item,
                requiresCustomIcon: item.type == "shortcut" || item.type == "link",
                websiteIconData: item.type == "link" ? (item.iconData ?? cachedWebsiteIconData) : nil,
                isWebsiteIconLoading: item.type == "link" && isFetchingLinkFavicon,
                onDefault: {
                    guard item.type != "shortcut" else { return }
                    place(item)
                    pendingIconItem = nil
                },
                onIconData: { iconData in
                    place(item.withIconData(iconData))
                    pendingIconItem = nil
                    if item.type == "link" {
                        clearLinkFields()
                    }
                },
                onCancel: {
                    pendingIconItem = nil
                    if item.type == "link" {
                        clearLinkFields()
                    }
                }
            )
            .frame(width: 520, height: 260)
        }
    }

    private var topBar: some View {
        ZStack {
            Picker("", selection: $mode) {
                ForEach(AddBarMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 430)

            HStack {
                Spacer()
                Button {
                    close()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color(nsColor: .controlBackgroundColor), in: Circle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var shortcutContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            sheetHeader(
                icon: SavedShortcut(id: "shortcuts.header", title: "Shortcuts", type: "shortcut", target: "Shortcuts", icon: "sparkles", iconData: nil, createdAt: Date()),
                title: "Add Apple Shortcuts to this slot",
                subtitle: "Choose from your Mac shortcuts."
            )
            searchField(prompt: "Search shortcuts")
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(filteredShortcuts.prefix(100))) { shortcut in
                        AddSheetPlainRow(title: shortcut.name, buttonTitle: "Add") {
                            addAppleShortcut(shortcut)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var appContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            sheetHeader(
                icon: SavedShortcut(id: "apps.header", title: "Apps", type: "app", target: "", icon: "app.fill", iconData: nil, createdAt: Date()),
                title: "Add an app to this slot",
                subtitle: "Choose any available Mac app."
            )
            searchField(prompt: "Search apps")
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(filteredApps.prefix(140))) { app in
                        AddSheetRow(icon: .appPath(app.path), title: app.name, buttonTitle: "Add") {
                            addApp(app)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var linkContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            sheetHeader(
                icon: SavedShortcut(id: "links.header", title: "Links", type: "link", target: "", icon: "link", iconData: nil, createdAt: Date()),
                title: "Add a website link",
                subtitle: "Paste a URL and place it in this exact slot."
            )

            VStack(spacing: 10) {
                TextField("Name", text: $linkTitle)
                    .textFieldStyle(.roundedBorder)
                TextField("https://", text: $linkURL)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Spacer()

                if isFetchingLinkFavicon {
                    ProgressView()
                        .controlSize(.small)
                    Text("Finding website icon…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button(isFetchingLinkFavicon ? "Adding…" : "Add Link") { addLink() }
                    .buttonStyle(.borderedProminent)
                    .disabled(cleanLinkURL.isEmpty || isFetchingLinkFavicon)
            }
            Spacer()
        }
    }

    private func sheetHeader(icon: SavedShortcut, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            MacBarIcon(shortcut: icon, size: 54)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title3.weight(.semibold))
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
        }
    }

    private func searchField(prompt: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $search).textFieldStyle(.plain)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var cleanLinkURL: String { linkURL.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func addAppleShortcut(_ shortcut: AppleShortcut) {
        pendingIconItem = SavedShortcut(id: UUID().uuidString, title: shortcut.name, type: "shortcut", target: shortcut.name, icon: "sparkles", iconData: nil, createdAt: Date(), pageIndex: slot.pageIndex, slotIndex: slot.slotIndex, pageRows: slot.rows)
    }

    private func addApp(_ app: AvailableApp) {
        place(SavedShortcut(id: UUID().uuidString, title: app.name, type: "app", target: app.path, icon: app.icon, iconData: nil, createdAt: Date(), pageIndex: slot.pageIndex, slotIndex: slot.slotIndex, pageRows: slot.rows))
    }

    private func addLink() {
        var url = normalizedLinkURL
        guard !url.isEmpty else { return }

        let title = linkTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? URL(string: url)?.host ?? url : linkTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = SavedShortcut(id: UUID().uuidString, title: title, type: "link", target: url, icon: "link", iconData: nil, createdAt: Date(), pageIndex: slot.pageIndex, slotIndex: slot.slotIndex, pageRows: slot.rows)

        if lastFetchedLogoURL == url {
            pendingIconItem = item.withIconData(cachedWebsiteIconData)
            clearLinkFields(keepCachedIcon: true)
            return
        }

        guard !isFetchingLinkFavicon else { return }
        isFetchingLinkFavicon = true

        MacCustomIconSource.fetchWebsiteLogoBase64(for: url) { iconData in
            isFetchingLinkFavicon = false
            lastFetchedLogoURL = url
            cachedWebsiteIconData = iconData
            refreshOpenLinkPicker(with: item, iconData: iconData)
            clearLinkFields(keepCachedIcon: true)
        }
    }

    private var normalizedLinkURL: String {
        var url = cleanLinkURL
        guard !url.isEmpty else { return "" }

        if !url.lowercased().hasPrefix("http://") && !url.lowercased().hasPrefix("https://") {
            url = "https://" + url
        }

        return url
    }

    private func refreshOpenLinkPicker(with item: SavedShortcut, iconData: String?) {
        let refreshedItem = item.withIconData(iconData)

        // Force SwiftUI to rebuild the sheet content so Website Icon stops showing unavailable.
        pendingIconItem = nil

        DispatchQueue.main.async {
            pendingIconItem = refreshedItem
        }
    }

    private func clearLinkFields(keepCachedIcon: Bool = false) {
        linkTitle = ""
        linkURL = ""

        if !keepCachedIcon {
            cachedWebsiteIconData = nil
            lastFetchedLogoURL = ""
        }
    }

    private func place(_ item: SavedShortcut) {
        guard (item.type != "shortcut" && item.type != "link") || (item.iconData?.isEmpty == false) else {
            return
        }

        let cleanItem = placementSafeShortcut(item)

        DispatchQueue.main.async {
            server.shortcuts.removeAll { existing in
                (existing.pageIndex == slot.pageIndex && existing.slotIndex == slot.slotIndex) ||
                (existing.type == cleanItem.type && existing.target == cleanItem.target)
            }

            server.shortcuts.append(cleanItem)

            // Send the realtime delta before disk save and before closing the sheet.
            // This keeps the iPhone update on the fastest possible path.
            server.pushLaunchpadDeltaUpsert(cleanItem)

            DispatchQueue.global(qos: .utility).async {
                RewindpadShortcutDiskStore.save(server.shortcuts)
            }

            close()
        }
    }

    private func placementSafeShortcut(_ item: SavedShortcut) -> SavedShortcut {
        let iconData: String?
        if item.type == "shortcut" || item.type == "link" {
            iconData = MacPersistentIconStore.persistentReference(for: item.iconData)
        } else {
            iconData = nil
        }

        return SavedShortcut(
            id: item.id,
            title: item.title,
            type: item.type,
            target: item.target,
            icon: item.icon,
            iconData: iconData,
            createdAt: item.createdAt,
            pageIndex: item.pageIndex,
            slotIndex: item.slotIndex,
            pageRows: item.pageRows
        )
    }



    private func close() {
        onClose()
        dismiss()
    }
}

struct MacIconChoiceSheet: View {
    let title: String
    let subtitle: String
    let defaultLabel: String
    let defaultIcon: SavedShortcut
    var requiresCustomIcon: Bool = false
    var websiteIconData: String? = nil
    var isWebsiteIconLoading: Bool = false
    let onDefault: () -> Void
    let onIconData: (String) -> Void
    let onCancel: () -> Void

    @State private var emoji = ""
    @State private var selectedMode = "website"
    @FocusState private var emojiFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                MacBarIcon(shortcut: previewIcon, size: 48)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.title3.weight(.semibold))
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color(nsColor: .controlBackgroundColor), in: Circle())
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 10) {
                if defaultIcon.type == "link" {
                    Button {
                        if let websiteIconData {
                            onIconData(websiteIconData)
                        }
                    } label: {
                        iconChoiceButton(
                            title: "Website Icon",
                            systemImage: isWebsiteIconLoading ? "clock" : "globe",
                            isSelected: selectedMode == "website",
                            isDisabled: websiteIconData == nil
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(websiteIconData == nil)
                    .opacity(websiteIconData == nil ? 0.42 : 1)
                } else if !requiresCustomIcon {
                    Button {
                        onDefault()
                    } label: {
                        iconChoiceButton(title: defaultLabel, systemImage: "sparkles")
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    selectedMode = "emoji"
                    emoji = ""
                    emojiFieldFocused = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        NSApp.orderFrontCharacterPalette(nil)
                    }
                } label: {
                    iconChoiceButton(title: "Emoji", systemImage: "face.smiling", isSelected: selectedMode == "emoji")
                }
                .buttonStyle(.plain)

                Button {
                    selectedMode = "image"
                    if let iconData = MacCustomIconSource.chooseImageBase64() {
                        onIconData(iconData)
                    }
                } label: {
                    iconChoiceButton(title: "Image", systemImage: "photo", isSelected: selectedMode == "image")
                }
                .buttonStyle(.plain)
            }

            if defaultIcon.type == "link", websiteIconData == nil {
                Text("Website Icon is unavailable for this site. Use Emoji or Image instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("", text: $emoji)
                .frame(width: 0, height: 0)
                .opacity(0.01)
                .focused($emojiFieldFocused)
                .onChange(of: emoji) { newValue in
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }

                    let selected = String(trimmed.prefix(1))
                    if let iconData = MacCustomIconSource.emojiBase64(selected) {
                        onIconData(iconData)
                    }
                }

            Spacer(minLength: 0)
        }
        .padding(22)
        .background(MacLiquidBackground())
    }

    private var previewIcon: SavedShortcut {
        if defaultIcon.type == "link", selectedMode == "website", let websiteIconData {
            return defaultIcon.withIconData(websiteIconData)
        }

        if selectedMode == "emoji", let iconData = MacCustomIconSource.emojiBase64(emoji) {
            return defaultIcon.withIconData(iconData)
        }

        return defaultIcon
    }

    private func iconChoiceButton(title: String, systemImage: String, isSelected: Bool = false, isDisabled: Bool = false) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
            Text(title)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(isDisabled ? Color.secondary : Color.primary)
        .frame(maxWidth: .infinity)
        .frame(height: 74)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isSelected ? Color.accentColor.opacity(0.72) : Color.primary.opacity(0.08), lineWidth: isSelected ? 1.5 : 1)
        }
    }
}

struct AddSheetPlainRow: View {
    let title: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            Button(buttonTitle) { action() }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }
}

enum AddRowIcon {
    case shortcut(String?)
    case appPath(String)
}

struct AddSheetRow: View {
    let icon: AddRowIcon
    let title: String
    let buttonTitle: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            rowIcon
            Text(title)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Button(buttonTitle) { action() }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var rowIcon: some View {
        switch icon {
        case .shortcut(let iconData):
            AddRowImage(iconData: iconData, appPath: nil, fallback: "sparkles", fallbackTint: .purple)
        case .appPath(let path):
            AddRowImage(iconData: nil, appPath: path, fallback: "app.fill", fallbackTint: .accentColor)
        }
    }
}

struct AddRowImage: View {
    let iconData: String?
    let appPath: String?
    let fallback: String
    let fallbackTint: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .frame(width: 34, height: 34)
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                }

            if let nsImage = image {
                Image(nsImage: nsImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            } else {
                Image(systemName: fallback)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(fallbackTint)
            }
        }
    }

    private var image: NSImage? {
        MacIconImageCache.shared.image(forAppPath: appPath) ?? MacIconImageCache.shared.image(forBase64: iconData)
    }
}

struct AboutMacView: View {
    @ObservedObject var server: RewindpadServer
    @State private var activeSupportTopic: SupportTopic? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header
                supportSection
                Spacer(minLength: 0)
            }
            .frame(maxWidth: 440)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 40)
            .padding(.top, 56)
            .padding(.bottom, 40)
        }
        .sheet(item: $activeSupportTopic) { topic in
            SupportRequestSheet(topic: topic)
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            RewindpadAboutAppIcon()
                .frame(width: 96, height: 96)
                .padding(.bottom, 12)

            Text("Launchpad")
                .font(.largeTitle.weight(.bold))

            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text("A faster way to reach your Mac.")
                .font(.body)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity)
    }

    private var supportSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                AboutSupportRow(
                    title: "Help & Support",
                    subtitle: "Questions about using Launchpad",
                    systemImage: "questionmark.circle"
                ) { activeSupportTopic = .help }
                Divider().padding(.leading, 48)
                AboutSupportRow(
                    title: "Feature Request",
                    subtitle: "Suggest an idea or improvement",
                    systemImage: "lightbulb"
                ) { activeSupportTopic = .feature }
                Divider().padding(.leading, 48)
                AboutSupportRow(
                    title: "Report a Bug",
                    subtitle: "Something isn't working right",
                    systemImage: "ant"
                ) { activeSupportTopic = .bug }
            }
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
            )
        }
        .frame(maxWidth: .infinity)
    }
}

struct RewindpadAboutAppIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(hex: "#1e6fd9"), Color(hex: "#0a4ab8")],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75)
                }

            Image("WorkspaceIcon")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white)
                .padding(22)
        }
        .accessibilityHidden(true)
    }
}

/// Native support sender — POSTs the message to the Rewindpad relay endpoint
/// over HTTPS. Works on any Mac with no mail setup. See SupportRelay/README.md
/// in the repo for the 5-minute backend deploy.
enum SupportRelay {
    static let endpoint = URL(string: "https://rewindpad-support.safelibrahim.workers.dev/send")!
    static var isConfigured: Bool { !endpoint.absoluteString.contains("YOUR-WORKER") }
    /// Shared token the worker checks — keeps drive-by spam out.
    static let token = "rwp_support_v1"

    static func send(topic: String, message: String, replyTo: String = "") async -> Bool {
        guard isConfigured else { return false }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-Rewindpad-Token")
        let payload: [String: String] = [
            "topic": topic,
            "message": message,
            "replyTo": replyTo,
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            "macos": ProcessInfo.processInfo.operatingSystemVersionString
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return false }
        return true
    }
}

enum AboutMailHelper {
    static let email = "safelibrahim@gmail.com"

    static func supportURL(subject: String, body: String? = nil) -> URL {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = email
        var items = [URLQueryItem(name: "subject", value: subject)]
        if let body, !body.isEmpty {
            items.append(URLQueryItem(name: "body", value: body))
        }
        components.queryItems = items
        return components.url ?? URL(fileURLWithPath: "/")
    }

    static func openSupportEmail(subject: String, body: String? = nil) {
        NSWorkspace.shared.open(supportURL(subject: subject, body: body))
    }

    /// Sends the message directly through Mail via Apple Events — no compose
    /// window. Returns false when Mail isn't available or automation was
    /// denied, so the caller can fall back to a mailto: compose draft.
    static func sendNatively(subject: String, body: String) -> Bool {
        func escaped(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
        }
        let source = """
        tell application "Mail"
            set msg to make new outgoing message with properties {subject:"\(escaped(subject))", content:"\(escaped(body))", visible:false}
            tell msg to make new to recipient at end of to recipients with properties {address:"\(email)"}
            send msg
        end tell
        """
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        script.executeAndReturnError(&error)
        return error == nil
    }
}

enum SupportTopic: String, Identifiable, CaseIterable {
    case help    = "Help & Support"
    case feature = "Feature Request"
    case bug     = "Report a Bug"

    var id: String { rawValue }

    var prompt: String {
        switch self {
        case .help:    return "What can we help you with?"
        case .feature: return "What would make Launchpad better for you?"
        case .bug:     return "What happened, and what did you expect instead?"
        }
    }
}

struct SupportRequestSheet: View {
    let topic: SupportTopic
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var email = UserDefaults.standard.string(forKey: "rw_support_email") ?? ""
    @State private var isSending = false
    @State private var sent = false

    private var emailIsValid: Bool {
        let t = email.trimmingCharacters(in: .whitespaces)
        return t.contains("@") && t.contains(".") && t.count >= 6
    }

    private var canSend: Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && emailIsValid
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if sent {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(.green)
                    Text("Message sent")
                        .font(.title3.weight(.semibold))
                    Text("Thanks — we'll reply to your email address.")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(topic.rawValue)
                        .font(.title3.weight(.semibold))
                    Text(topic.prompt)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Your email")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("name@example.com", text: $email)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .strokeBorder(email.isEmpty || emailIsValid
                                              ? Color.primary.opacity(0.10)
                                              : Color.orange.opacity(0.5), lineWidth: 1)
                        )
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Message")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextEditor(text: $message)
                        .font(.system(size: 14))
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .frame(height: 140)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
                        )
                }

                Text("We'll reply to the address above.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)

                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .controlSize(.large)
                        .keyboardShortcut(.cancelAction)
                    Button {
                        send()
                    } label: {
                        if isSending {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small)
                                Text("Sending…")
                            }
                        } else {
                            Text("Send")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!canSend || isSending)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func send() {
        isSending = true
        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)
        UserDefaults.standard.set(trimmedEmail, forKey: "rw_support_email")
        let subject = "\(topic.rawValue) — Launchpad"
        let body = "\(message)\n\nFrom: \(trimmedEmail)"
        Task {
            // 1. Native HTTPS relay — works on any Mac, no mail setup needed.
            var ok = await SupportRelay.send(topic: topic.rawValue, message: message, replyTo: trimmedEmail)

            // 2. Fall back to sending through the user's Mail via Apple Events.
            if !ok {
                ok = await Task.detached(priority: .userInitiated) {
                    AboutMailHelper.sendNatively(subject: subject, body: body)
                }.value
            }

            isSending = false
            if ok {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { sent = true }
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                dismiss()
            } else {
                // 3. Last resort — pre-filled compose draft.
                AboutMailHelper.openSupportEmail(subject: subject, body: body)
                dismiss()
            }
        }
    }
}

struct AboutSupportRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 17))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(isHovered ? Color.primary.opacity(0.05) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .help("Opens your email app")
    }
}





extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:  (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:  (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:  (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (255, 200, 200, 200)
        }
        self.init(.sRGB, red: Double(r)/255, green: Double(g)/255,
                  blue: Double(b)/255, opacity: Double(a)/255)
    }
}
