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
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(alignment: .firstTextBaseline) {
                            Text("Workspaces")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Text("·").foregroundStyle(.tertiary).font(.system(size: 13))
                            Text("\(server.appGroups.count)")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Button {
                                editingGroup = nil
                                showCreator = true
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 11, weight: .semibold))
                                    Text("New Workspace")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Color.accentColor, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 22)
                        .padding(.bottom, 14)

                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(server.appGroups) { group in
                                AppGroupCard(group: group) {
                                    editingGroup = group
                                    showCreator = true
                                } onDelete: {
                                    server.removeAppGroup(id: group.id)
                                }
                            }
                        }
                        .padding(.horizontal, 24)
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Image(systemName: group.layout.icon)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("\(group.layout.displayName)  ·  \(group.apps.count) app\(group.apps.count == 1 ? "" : "s")")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if isHovered {
                    HStack(spacing: 6) {
                        Button(action: onEdit) {
                            Image(systemName: "pencil")
                                .font(.system(size: 11, weight: .medium))
                                .frame(width: 26, height: 26)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help("Edit")
                        Button { showDeleteConfirm = true } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.red)
                                .frame(width: 26, height: 26)
                                .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help("Delete")
                    }
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
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
        .onTapGesture(count: 2, perform: onEdit)
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

    private var conflictIsHorizontal: Bool {
        switch group.layout {
        case .split1x1, .split1x2, .split2x1: return true
        default: return false
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(
                    colors: [Color.black.opacity(0.28), Color.black.opacity(0.18)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
                .background(Color(nsColor: .windowBackgroundColor))
                layoutDiagram(in: geo.size)
            }
        }
        .onChange(of: conflicting) { _, isConflicting in
            if isConflicting {
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) { collide = true }
            } else {
                withAnimation(.spring(duration: 0.3)) { collide = false }
            }
        }
        .onAppear {
            if conflicting {
                withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) { collide = true }
            }
        }
    }

    @ViewBuilder
    private func layoutDiagram(in size: CGSize) -> some View {
        let pad: CGFloat = 12
        let gap: CGFloat = 4
        let c = CGRect(x: pad, y: pad, width: size.width - pad * 2, height: size.height - pad * 2)
        let apps = group.apps.filter { !($0.isShortcut && $0.shortcutRunMode == .background) }

        switch group.layout {
        case .split1x1:
            let hw = (c.width - gap) / 2
            windowPane(CGRect(x: c.minX, y: c.minY, width: hw, height: c.height), appIndex: 0, apps: apps)
            windowPane(CGRect(x: c.minX + hw + gap, y: c.minY, width: c.width - hw - gap, height: c.height), appIndex: 1, apps: apps)
        case .split1x1v:
            let hh = (c.height - gap) / 2
            windowPane(CGRect(x: c.minX, y: c.minY, width: c.width, height: hh), appIndex: 0, apps: apps)
            windowPane(CGRect(x: c.minX, y: c.minY + hh + gap, width: c.width, height: c.height - hh - gap), appIndex: 1, apps: apps)
        case .split1x2:
            let mw = (c.width * 0.60).rounded()
            let sw = c.width - mw - gap
            let sc = max(apps.count - 1, 1)
            let sh = (c.height - gap * CGFloat(sc - 1)) / CGFloat(sc)
            windowPane(CGRect(x: c.minX, y: c.minY, width: mw, height: c.height), appIndex: 0, apps: apps)
            ForEach(0..<sc, id: \.self) { i in
                let sy = c.minY + CGFloat(i) * (sh + gap)
                windowPane(CGRect(x: c.minX + mw + gap, y: sy, width: sw, height: sh), appIndex: i + 1, apps: apps)
            }
        case .split2x1:
            let sw = (c.width * 0.40).rounded()
            let mw = c.width - sw - gap
            let sc = max(apps.count - 1, 1)
            let sh = (c.height - gap * CGFloat(sc - 1)) / CGFloat(sc)
            ForEach(0..<sc, id: \.self) { i in
                let sy = c.minY + CGFloat(i) * (sh + gap)
                windowPane(CGRect(x: c.minX, y: sy, width: sw, height: sh), appIndex: i + 1, apps: apps)
            }
            windowPane(CGRect(x: c.minX + sw + gap, y: c.minY, width: mw, height: c.height), appIndex: 0, apps: apps)
        case .split1x2h:
            let mh = (c.height * 0.60).rounded()
            let bh = c.height - mh - gap
            let bc = max(apps.count - 1, 1)
            let bw = (c.width - gap * CGFloat(bc - 1)) / CGFloat(bc)
            windowPane(CGRect(x: c.minX, y: c.minY, width: c.width, height: mh), appIndex: 0, apps: apps)
            ForEach(0..<bc, id: \.self) { i in
                let bx = c.minX + CGFloat(i) * (bw + gap)
                windowPane(CGRect(x: bx, y: c.minY + mh + gap, width: bw, height: bh), appIndex: i + 1, apps: apps)
            }
        case .grid2x2:
            let hw = (c.width - gap) / 2
            let hh = (c.height - gap) / 2
            let slots: [CGRect] = [
                CGRect(x: c.minX,          y: c.minY,          width: hw,                height: hh),
                CGRect(x: c.minX + hw+gap, y: c.minY,          width: c.width - hw - gap, height: hh),
                CGRect(x: c.minX,          y: c.minY + hh+gap, width: hw,                height: c.height - hh - gap),
                CGRect(x: c.minX + hw+gap, y: c.minY + hh+gap, width: c.width - hw - gap, height: c.height - hh - gap),
            ]
            ForEach(0..<min(max(apps.count, 1), 4), id: \.self) { i in
                windowPane(slots[i], appIndex: i, apps: apps)
            }
        }
    }

    @ViewBuilder
    private func windowPane(_ frame: CGRect, appIndex: Int, apps: [AppGroupEntry]) -> some View {
        let isPrimary = apps.indices.contains(appIndex) && apps[appIndex].id == group.primaryAppID
        let entry: AppGroupEntry? = apps.indices.contains(appIndex) ? apps[appIndex] : nil
        let isColliding = conflicting && appIndex < 2
        let push: CGFloat = 5
        let dx: CGFloat = isColliding ? (appIndex == 0 ? (conflictIsHorizontal ? push : 0) : (conflictIsHorizontal ? -push : 0)) : 0
        let dy: CGFloat = isColliding ? (appIndex == 0 ? (conflictIsHorizontal ? 0 : push) : (conflictIsHorizontal ? 0 : -push)) : 0

        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isColliding && collide ? Color.red.opacity(0.20)
                      : (isPrimary ? Color.white.opacity(0.13) : Color.white.opacity(0.07)))
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isColliding && collide ? Color.red.opacity(0.85)
                              : Color.white.opacity(isPrimary ? 0.22 : 0.10), lineWidth: 0.75)

            if let entry {
                VStack(spacing: 3) {
                    if let img = MacIconImageCache.shared.image(forAppPath: entry.path) {
                        Image(nsImage: img)
                            .resizable().aspectRatio(contentMode: .fit)
                            .frame(width: min(frame.width * 0.36, 32), height: min(frame.height * 0.40, 32))
                            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
                    } else {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white.opacity(0.12))
                            .frame(width: min(frame.width * 0.30, 24), height: min(frame.height * 0.34, 24))
                    }
                    if frame.width > 60 && frame.height > 52 {
                        Text(entry.appName)
                            .font(.system(size: min(frame.width * 0.088, 9), weight: .medium))
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1)
                    }
                }
            }
            if isPrimary {
                VStack {
                    HStack {
                        Spacer()
                        Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                            .shadow(color: Color.accentColor.opacity(0.8), radius: 3)
                            .padding(5)
                    }
                    Spacer()
                }
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
    @Environment(\.dismiss) private var dismiss

    private let steps = ["Name", "Layout", "Modules", "Settings"]

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
        let all = server.availableApps.sorted { $0.name < $1.name }
        guard !q.isEmpty else { return all }
        return all.filter { $0.name.lowercased().contains(q) }
    }

    private var previewGroup: AppGroup {
        AppGroup(id: existing?.id ?? "preview",
                 name: name.isEmpty ? "My Workspace" : name,
                 icon: icon, apps: selectedApps, layout: layout,
                 primaryAppID: primaryAppID ?? selectedApps.first?.id,
                 createdAt: existing?.createdAt ?? Date())
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !selectedApps.isEmpty
    }

    private var hardConflict: (String, String)? {
        guard let screen = NSScreen.screens.first else { return nil }
        let vis = selectedApps.filter { !($0.isShortcut && $0.shortcutRunMode == .background) }
        return server.conflictPair(entries: vis, layout: layout, screen: screen)
    }

    var body: some View {
        VStack(spacing: 0) {
            // ── Top bar ────────────────────────────────────────────────────
            HStack(alignment: .center, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(existing == nil ? "New Workspace" : "Edit Workspace")
                        .font(.system(size: 16, weight: .semibold))
                    Text(name.isEmpty ? "Follow the steps below" : name)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if existing != nil, let onDelete {
                    Button { showDeleteConfirm = true } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "trash").font(.system(size: 11, weight: .medium))
                            Text("Delete").font(.system(size: 12))
                        }
                        .foregroundStyle(.red.opacity(0.85))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.red.opacity(0.18), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .confirmationDialog("Delete \"\(name.isEmpty ? "this workspace" : name)\"?",
                                        isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                        Button("Delete Workspace", role: .destructive) { dismiss(); onDelete() }
                        Button("Cancel", role: .cancel) {}
                    } message: { Text("This cannot be undone.") }
                }
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(Color.primary.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 10)
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 16)

            // ── Step progress ──────────────────────────────────────────────
            HStack(spacing: 0) {
                ForEach(steps.indices, id: \.self) { i in
                    stepNode(index: i)
                    if i < steps.count - 1 {
                        Rectangle()
                            .fill(i < currentStep ? Color.accentColor : Color.primary.opacity(0.12))
                            .frame(maxWidth: .infinity).frame(height: 2)
                    }
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 20)

            Divider()

            // ── Left content + right preview ───────────────────────────────
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            stepContent.padding(24)
                        }
                    }
                    Divider()
                    // Bottom nav
                    HStack {
                        if currentStep > 0 {
                            Button {
                                withAnimation(.easeInOut(duration: 0.22)) { currentStep -= 1 }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                                    Text("Back").font(.system(size: 13, weight: .medium))
                                }
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                        Text("Step \(currentStep + 1) of \(steps.count)")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        if currentStep < steps.count - 1 {
                            Button {
                                withAnimation(.easeInOut(duration: 0.22)) { currentStep += 1 }
                            } label: {
                                HStack(spacing: 5) {
                                    Text("Continue").font(.system(size: 13, weight: .semibold))
                                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .disabled(currentStep == 0 && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        } else {
                            Button { onSave(makeGroup()) } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                                    Text("Save Workspace").font(.system(size: 13, weight: .semibold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .background(isValid ? Color.accentColor : Color.secondary.opacity(0.4),
                                            in: RoundedRectangle(cornerRadius: 8))
                            }
                            .buttonStyle(.plain)
                            .disabled(!isValid)
                            .keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 14)
                }
                .frame(width: 380)

                Divider()

                // Right: live preview panel
                previewPanel.frame(maxWidth: .infinity)
            }
        }
        .frame(width: 780, height: 580)
        .background(MacLiquidBackground())
    }

    // MARK: Step node
    @ViewBuilder
    private func stepNode(index: Int) -> some View {
        let state: StepState = index < currentStep ? .done : index == currentStep ? .active : .upcoming
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(state == .upcoming ? Color.clear : Color.accentColor)
                    .frame(width: 26, height: 26)
                Circle()
                    .strokeBorder(state == .upcoming ? Color.primary.opacity(0.18) : Color.accentColor,
                                  lineWidth: state == .upcoming ? 1.5 : 0)
                    .frame(width: 26, height: 26)
                if state == .done {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(index + 1)").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(state == .active ? .white : .secondary)
                }
            }
            Text(steps[index])
                .font(.system(size: 10, weight: state == .active ? .semibold : .regular))
                .foregroundStyle(state == .active ? .primary : .secondary)
        }
    }

    private enum StepState { case done, active, upcoming }

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case 0: stepName
        case 1: stepLayout
        case 2: stepModules
        default: stepSettings
        }
    }

    // MARK: Step 0 — Name
    private var stepName: some View {
        VStack(alignment: .leading, spacing: 24) {
            stepHeader(icon: "pencil.line", title: "Name your Workspace",
                       subtitle: "Give this environment a clear, memorable name.")
            VStack(alignment: .leading, spacing: 6) {
                Text("Workspace name").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                TextField("e.g. Work Mode, Deep Focus, Design…", text: $name)
                    .textFieldStyle(.plain).font(.system(size: 14))
                    .padding(10)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(
                        name.isEmpty ? Color.primary.opacity(0.10) : Color.accentColor.opacity(0.45), lineWidth: 1))
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Suggestions").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                FlowRow(spacing: 6) {
                    ForEach(["Work Mode", "Deep Focus", "Design", "Research", "Morning Routine", "Dev Setup"], id: \.self) { s in
                        Button { name = s } label: {
                            Text(s).font(.system(size: 12))
                                .foregroundStyle(name == s ? Color.accentColor : .primary)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(name == s ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.06), in: Capsule())
                                .overlay(Capsule().strokeBorder(name == s ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: Step 1 — Layout
    private var stepLayout: some View {
        VStack(alignment: .leading, spacing: 24) {
            stepHeader(icon: "rectangle.3.group", title: "Choose a layout",
                       subtitle: "Pick how your windows will be arranged on screen.")
            VStack(spacing: 8) {
                ForEach(layoutGroups, id: \.label) { grp in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(grp.label).font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary).textCase(.uppercase).tracking(0.5)
                        HStack(spacing: 8) {
                            ForEach(grp.options, id: \.self) { opt in layoutCard(opt) }
                            Spacer()
                        }
                    }
                    if grp.label != layoutGroups.last?.label { Divider().padding(.vertical, 4) }
                }
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
            VStack(spacing: 8) {
                LayoutIconView(layout: opt, size: 32, color: selected ? .white : Color.accentColor, cornerRadius: 2)
                    .frame(width: 60, height: 48)
                    .background(selected ? Color.accentColor : Color.accentColor.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(
                        selected ? Color.accentColor : Color.primary.opacity(0.10), lineWidth: 1))
                Text(opt.displayName)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .multilineTextAlignment(.center).frame(width: 68)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: Step 2 — Modules
    private var stepModules: some View {
        VStack(alignment: .leading, spacing: 20) {
            stepHeader(icon: "square.stack.3d.up", title: "Add modules",
                       subtitle: "Apps, links, and shortcuts that launch with this Workspace.")
            if !selectedApps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Added (\(selectedApps.count))").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    VStack(spacing: 2) {
                        ForEach(selectedApps) { entry in selectedAppRow(entry) }
                    }
                    .padding(8)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Apps").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
                    TextField("Search apps…", text: $searchText)
                }
                .padding(8)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(filteredApps.prefix(80)) { app in availableAppRow(app) }
                    }
                }
                .frame(height: 160)
                .background(Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Link / Website").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "link").foregroundStyle(.secondary).font(.system(size: 12))
                        TextField("https://…", text: $urlInput).textFieldStyle(.plain).font(.system(size: 12))
                    }
                    .padding(8).frame(maxWidth: .infinity)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                    Picker("", selection: $browserChoice) {
                        ForEach(BrowserChoice.allCases, id: \.self) { b in
                            HStack { Image(systemName: b.sfSymbol); Text(b.appName) }.tag(b)
                        }
                    }
                    .labelsHidden().frame(width: 110)
                    Button { addBrowserTab() } label: {
                        Text("Add").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .disabled(urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if !server.availableShortcuts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Image(systemName: "bolt.fill").foregroundStyle(.purple).font(.system(size: 10))
                        Text("Shortcuts").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
                        TextField("Search shortcuts…", text: $shortcutSearchText)
                    }
                    .padding(8)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                    let fsc: [AppleShortcut] = {
                        let q = shortcutSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        return q.isEmpty ? Array(server.availableShortcuts)
                            : server.availableShortcuts.filter { $0.name.lowercased().contains(q) }
                    }()
                    ScrollView {
                        LazyVStack(spacing: 1) { ForEach(fsc.prefix(60)) { s in availableShortcutRow(s) } }
                    }
                    .frame(height: 110)
                    .background(Color.primary.opacity(0.02), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5))
                }
            }
        }
    }

    // MARK: Step 3 — Settings
    private var stepSettings: some View {
        VStack(alignment: .leading, spacing: 24) {
            stepHeader(icon: "slider.horizontal.3", title: "Final settings",
                       subtitle: "Decide what happens when you stop this Workspace.")
            VStack(alignment: .leading, spacing: 6) {
                Text("When stopped").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    ForEach(AppGroupStopBehavior.allCases, id: \.self) { option in
                        Button { stopBehavior = option } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle().strokeBorder(stopBehavior == option ? Color.accentColor : Color.primary.opacity(0.22), lineWidth: 1.5).frame(width: 18, height: 18)
                                    if stopBehavior == option { Circle().fill(Color.accentColor).frame(width: 9, height: 9) }
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label).font(.system(size: 13, weight: .medium))
                                    Text(option.description).font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 14).padding(.vertical, 12)
                            .background(stopBehavior == option ? Color.accentColor.opacity(0.06) : Color.clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if option != AppGroupStopBehavior.allCases.last { Divider().padding(.leading, 44) }
                    }
                }
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.09), lineWidth: 0.5))
            }
            if !selectedApps.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Workspace summary").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        AppGroupMacIcon(group: previewGroup, size: 40)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(name.isEmpty ? "Unnamed Workspace" : name).font(.system(size: 14, weight: .semibold))
                            HStack(spacing: 6) {
                                Text(layout.displayName).font(.system(size: 11)).foregroundStyle(.secondary)
                                Text("·").foregroundStyle(.tertiary)
                                Text("\(selectedApps.count) modules").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
                }
            }
        }
    }

    // MARK: Right preview panel
    private var previewPanel: some View {
        VStack(spacing: 0) {
            HStack {
                HStack(spacing: 5) {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                    Text("Live Preview").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                }
                Spacer()
                if !name.isEmpty {
                    Text(name).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(Color.primary.opacity(0.03))
            Divider()
            ScrollView {
                VStack(spacing: 16) {
                    AppGroupLayoutPreview(group: previewGroup, conflicting: hardConflict != nil)
                        .frame(height: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))

                    if let (a, b) = hardConflict {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                            Text("\(a) and \(b) can't fit side-by-side — minimum widths exceed the screen.")
                                .font(.caption).foregroundStyle(.primary)
                        }
                        .padding(10)
                        .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }

                    if !selectedApps.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Window positions").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            ForEach(Array(selectedApps.prefix(4).enumerated()), id: \.element.id) { i, entry in
                                HStack(spacing: 8) {
                                    Text("\(i + 1)").font(.system(size: 10, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white).frame(width: 18, height: 18)
                                        .background(entry.id == primaryAppID ? Color.accentColor : Color.secondary.opacity(0.4), in: Circle())
                                    AppGroupAppIcon(path: entry.path, name: entry.appName)
                                    Text(entry.appName).font(.system(size: 12)).lineLimit(1)
                                    Spacer()
                                    Text(positionLabel(index: i, layout: layout))
                                        .font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                                        .padding(.horizontal, 7).padding(.vertical, 2)
                                        .background(.quaternary, in: Capsule())
                                }
                            }
                        }
                        .padding(12)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
                    } else {
                        VStack(spacing: 8) {
                            Image(systemName: "square.dashed").font(.system(size: 24, weight: .light)).foregroundStyle(.tertiary)
                            Text("Add modules to see\nyour Workspace take shape")
                                .font(.system(size: 12)).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity).padding(.top, 10)
                    }

                    if currentStep < steps.count - 1 {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.right.circle.fill")
                                .foregroundStyle(Color.accentColor.opacity(0.7)).font(.system(size: 12))
                            Text(stepHint).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.15), lineWidth: 0.5))
                    }
                }
                .padding(16)
            }
        }
    }

    private var stepHint: String {
        switch currentStep {
        case 0: return "Name is used to identify this Workspace."
        case 1: return "Layout determines how windows are placed."
        case 2: return "Modules are opened when the Workspace launches."
        default: return "Review your Workspace before saving."
        }
    }

    private func stepHeader(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)).frame(width: 32, height: 32)
                Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.accentColor)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 15, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func selectedAppRow(_ entry: AppGroupEntry) -> some View {
        HStack(spacing: 8) {
            AppGroupAppIcon(path: entry.path, name: entry.appName)
            Text(entry.appName).font(.system(size: 13)).lineLimit(1)
            Spacer()
            if entry.id == primaryAppID {
                Text("Primary").font(.system(size: 10, weight: .semibold)).foregroundStyle(.blue)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
            }
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    selectedApps.removeAll { $0.id == entry.id }
                    if primaryAppID == entry.id { primaryAppID = selectedApps.first?.id }
                }
            } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.red.opacity(0.8)).font(.system(size: 15))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture { primaryAppID = entry.id }
    }

    @ViewBuilder
    private func availableAppRow(_ app: AvailableApp) -> some View {
        let added = selectedApps.contains { $0.id == app.id }
        HStack(spacing: 8) {
            AppGroupAppIcon(path: app.path, name: app.name)
            Text(app.name).font(.system(size: 13)).lineLimit(1)
            Spacer()
            if added { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor).font(.system(size: 15)) }
        }
        .padding(.vertical, 5).padding(.horizontal, 8)
        .background(added ? Color.accentColor.opacity(0.07) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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
        HStack(spacing: 8) {
            ZStack {
                Circle().fill(Color.purple.opacity(added ? 0.25 : 0.12))
                Image(systemName: "bolt.fill").font(.system(size: 10, weight: .medium)).foregroundStyle(Color.purple)
            }
            .frame(width: 24, height: 24)
            Text(shortcut.name).font(.system(size: 13)).lineLimit(1)
            Spacer()
            if added { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor).font(.system(size: 15)) }
        }
        .padding(.vertical, 5).padding(.horizontal, 8)
        .background(added ? Color.accentColor.opacity(0.07) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
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
        guard !raw.isEmpty else { return }
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
        urlInput = ""
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

    var body: some View {
        Group {
            if let img = MacIconImageCache.shared.image(forAppPath: path) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "app")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 26, height: 26)
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
                            .font(.caption)
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

                    // PIN block — collapsible
                    if showPairingPanel {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("PAIR IPHONE")
                                .font(.system(size: 9, weight: .heavy))
                                .tracking(1.1)
                                .foregroundStyle(.tertiary)

                            Text(server.pin)
                                .font(.system(size: 24, weight: .bold, design: .monospaced))
                                .foregroundStyle(.primary)
                                .kerning(3)

                            Text("Open Rewindpad on your iPhone and enter this PIN.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.quaternary.opacity(0.5),
                                    in: RoundedRectangle(cornerRadius: 9))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9)
                                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5)
                        )
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
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
            Divider()

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
        VStack(spacing: 7) {
            Text("Launchpad")
                .font(.largeTitle.weight(.semibold))
                .multilineTextAlignment(.center)

            Text("Organize your iPhone Launchpad view from your Mac.")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
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

    var body: some View {
        ScrollView {
            VStack(spacing: 42) {
                header

                supportSection

                Spacer(minLength: 0)
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 48)
            .padding(.top, 58)
            .padding(.bottom, 44)
        }
    }

    private var header: some View {
        VStack(spacing: 10) {
            RewindpadAboutAppIcon()
                .frame(width: 108, height: 108)
                .padding(.bottom, 10)

            Text("Launchpad")
                .font(.system(size: 38, weight: .heavy))
                .tracking(-0.8)

            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text("A faster way to reach your Mac.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
    }

    private var supportSection: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("Get help with Launchpad.")
                    .font(.system(size: 28, weight: .bold))
                    .tracking(-0.35)
                    .multilineTextAlignment(.center)

                Text("Questions, ideas, or something that needs fixing — send it straight from here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(2)
                    .frame(maxWidth: 520)
            }

            HStack(spacing: 16) {
                AboutSupportCard(
                    title: "Help & Support",
                    systemImage: "questionmark.circle",
                    action: {
                        AboutMailHelper.openSupportEmail(subject: "Help & Support — Launchpad")
                    }
                )

                AboutSupportCard(
                    title: "Feature Request",
                    systemImage: "sparkles",
                    action: {
                        AboutMailHelper.openSupportEmail(subject: "Feature Request — Launchpad")
                    }
                )

                AboutSupportCard(
                    title: "Bug Report",
                    systemImage: "ladybug",
                    action: {
                        AboutMailHelper.openSupportEmail(subject: "Bug Report — Launchpad")
                    }
                )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
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

enum AboutMailHelper {
    static let email = "safelibrahim@gmail.com"

    static func supportURL(subject: String) -> URL {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = email
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject)
        ]

        return components.url ?? URL(fileURLWithPath: "/")
    }

    static func openSupportEmail(subject: String) {
        NSWorkspace.shared.open(supportURL(subject: subject))
    }
}

struct AboutSupportCard: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                Image(systemName: systemImage)
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 32)

                Spacer(minLength: 16)

                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .aspectRatio(1, contentMode: .fit)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.10 : 0.06))
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isHovered)
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
