import Compression
import Foundation

/// Reads a `.deb`: an `ar` archive around a `tar` payload, usually gzip'd,
/// plus the `DEBIAN/control` fields a tweak's dependencies live in.
///
/// Only what injection needs is pulled out — the libraries and their names —
/// so a 20 MB package with preference bundles costs a few hundred kilobytes of
/// memory.
enum DebArchive {

    enum DebError: LocalizedError {
        case notADeb
        case unsupportedCompression(String)
        case damaged(String)

        var errorDescription: String? {
            switch self {
            case .notADeb:
                return L("That file isn't a .deb package.")
            case .unsupportedCompression(let name):
                return L("This .deb is compressed with %@, which SideInstaller can't unpack here. Repack it with gzip.", name)
            case .damaged(let part):
                return L("The .deb is damaged: %@.", part)
            }
        }
    }

    /// One library a package would install.
    struct Library {
        /// Path inside the package, e.g. `Library/MobileSubstrate/DynamicLibraries/Foo.dylib`.
        let path: String
        let data: Data
        /// True for a `.framework` binary, which is given the framework's name.
        let isFramework: Bool

        /// The file name to use inside the app's `Frameworks` folder.
        var fileName: String {
            if isFramework {
                let parts = path.split(separator: "/")
                let framework = parts.last(where: { $0.hasSuffix(".framework") }) ?? "Framework.framework"
                return String(framework.dropLast(".framework".count))
            }
            return (path as NSString).lastPathComponent
        }
    }

    /// What a package says about itself.
    struct Package {
        let identifier: String?
        let name: String?
        let version: String?
        /// Raw `Depends` field, e.g. `mobilesubstrate (>= 0.9.5000), firmware (>= 13.0)`.
        let depends: String?
        /// `iphoneos-arm64` for a rootless build, `iphoneos-arm` for rootful.
        let architecture: String?
        let libraries: [Library]

        /// The injector this package expects, in the vocabulary `Tweak` uses.
        var requiredInjector: TweakInjectorKind? {
            guard let depends else { return nil }
            let lowered = depends.lowercased()
            if lowered.contains("ellekit") { return .ellekit }
            if lowered.contains("libhooker") { return .libhooker }
            if lowered.contains("substitute") { return .substitute }
            if lowered.contains("mobilesubstrate") || lowered.contains("cydia substrate")
                || lowered.contains("mobilesubstrate") { return .substrate }
            return nil
        }
    }

    /// Unpacks `url` and returns what it carries.
    static func read(_ url: URL) throws -> Package {
        guard let data = try? Data(contentsOf: url, options: .uncached) else {
            throw DebError.damaged("it can't be read")
        }
        let members = try arMembers(data)
        let control = members.first { $0.name.hasPrefix("control.tar") }
        let payload = members.first { $0.name.hasPrefix("data.tar") }
        guard let payload else { throw DebError.notADeb }

        let fields = control.flatMap { member -> [String: String] in
            guard let raw = try? self.tar(member, data: data) else { return [:] }
            guard let entry = raw.first(where: { $0.path.hasSuffix("control") }) else { return [:] }
            return DebArchive.fields(in: entry.data)
        } ?? [:]

        let files = try tar(payload, data: data)
        var libraries: [Library] = []
        for entry in files where entry.isRegular {
            let path = entry.path
            let lowered = path.lowercased()
            // Where a rootless or rootful tweak keeps its library, plus any
            // stray dylib a package ships.
            let isDylib = lowered.hasSuffix(".dylib")
            let isFrameworkBinary = lowered.contains(".framework/")
                && !lowered.hasSuffix(".plist") && !lowered.hasSuffix("/")
                && !lowered.hasSuffix(".h") && !lowered.hasSuffix(".modulemap")
            guard isDylib || isFrameworkBinary else { continue }
            // Architecture is checked later, where injection already knows how
            // to read a Mach-O header.
            libraries.append(Library(path: path, data: entry.data, isFramework: isFrameworkBinary))
        }

        return Package(identifier: fields["package"],
                       name: fields["name"],
                       version: fields["version"],
                       depends: fields["depends"],
                       architecture: fields["architecture"],
                       libraries: libraries)
    }

    // MARK: - ar

    private struct Member {
        let name: String
        let offset: Int
        let size: Int
    }

    private static func arMembers(_ data: Data) throws -> [Member] {
        let magic = Data("!<arch>\n".utf8)
        guard data.count > 8, data.prefix(8) == magic else { throw DebError.notADeb }
        var out: [Member] = []
        var cursor = 8
        while cursor + 60 <= data.count {
            let header = data[(data.startIndex + cursor)...]
            func field(_ start: Int, _ length: Int) -> String {
                let slice = header[(header.startIndex + start)..<(header.startIndex + start + length)]
                return String(decoding: slice, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            }
            guard field(58, 2) == "`\n" else { break }
            var name = field(0, 16)
            if name.hasSuffix("/") { name.removeLast() }
            guard let size = Int(field(48, 10)) else { break }
            let start = cursor + 60
            guard start + size <= data.count else { throw DebError.damaged("an ar member runs past the end") }
            out.append(Member(name: name, offset: start, size: size))
            // Members are padded to an even offset.
            cursor = start + size + (size % 2)
        }
        guard !out.isEmpty else { throw DebError.notADeb }
        return out
    }

    // MARK: - tar

    private struct TarEntry {
        let path: String
        let size: Int
        let data: Data
        let isRegular: Bool
    }

    private static func tar(_ member: Member, data: Data) throws -> [TarEntry] {
        var payload = data.subdata(in: member.offset..<(member.offset + member.size))
        if member.name.hasSuffix(".gz") {
            payload = try gunzip(payload)
        } else if member.name.hasSuffix(".xz") || member.name.hasSuffix(".zst") {
            throw DebError.unsupportedCompression(member.name.hasSuffix(".xz") ? "xz" : "zstd")
        } else if !member.name.hasSuffix(".tar") {
            throw DebError.unsupportedCompression(member.name)
        }
        return try parseTar(payload)
    }

    private static func parseTar(_ data: Data) throws -> [TarEntry] {
        var out: [TarEntry] = []
        var cursor = 0
        var pendingLongName: String?
        let base = data.startIndex
        while cursor + 512 <= data.count {
            let block = data[(base + cursor)..<(base + cursor + 512)]
            // Two zero blocks end the archive; one is enough to stop.
            if block.allSatisfy({ $0 == 0 }) { break }
            func string(_ offset: Int, _ length: Int) -> String {
                let slice = block[(block.startIndex + offset)..<(block.startIndex + offset + length)]
                let bytes = slice.prefix { $0 != 0 }
                return String(decoding: bytes, as: UTF8.self)
            }
            func octal(_ offset: Int, _ length: Int) -> Int {
                let text = string(offset, length).trimmingCharacters(in: .whitespaces)
                return Int(text, radix: 8) ?? 0
            }

            let name = string(0, 100)
            let size = octal(124, 12)
            let type = string(156, 1)
            let prefix = string(345, 155)
            let dataStart = cursor + 512
            guard dataStart + size <= data.count else { throw DebError.damaged("a tar entry runs past the end") }
            let payload = data.subdata(in: (base + dataStart)..<(base + dataStart + size))

            switch type {
            case "L":                       // GNU long name: the next entry's
                pendingLongName = String(decoding: payload.prefix { $0 != 0 }, as: UTF8.self)
            case "x", "g":                  // pax headers carry nothing we need
                break
            case "5":                       // directory
                break
            case "1", "2":                  // link, symlink
                break
            default:
                var path = pendingLongName ?? (prefix.isEmpty ? name : prefix + "/" + name)
                if path.hasPrefix("./") { path.removeFirst(2) }
                path = path.hasPrefix("/") ? String(path.dropFirst()) : path
                pendingLongName = nil
                if !payload.isEmpty {
                    out.append(TarEntry(path: path, size: size, data: payload, isRegular: true))
                }
            }
            cursor = dataStart + ((size + 511) / 512) * 512
        }
        return out
    }

    /// `DEBIAN/control`: `Key: value` lines, continuation lines folded.
    private static func fields(in data: Data) -> [String: String] {
        var out: [String: String] = [:]
        var lastKey: String?
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                if let lastKey { out[lastKey] = (out[lastKey] ?? "") + "\n" + line.trimmingCharacters(in: .whitespaces) }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            out[key] = value
            lastKey = key
        }
        return out
    }

    // MARK: - gzip

    /// A gzip member: a 10-byte header with optional fields, then a raw DEFLATE
    /// stream (`COMPRESSION_ZLIB` is exactly that), then the CRC and size.
    static func gunzip(_ data: Data, limit: Int = 64 << 20) throws -> Data {
        guard data.count > 18,
              data[data.startIndex] == 0x1F, data[data.startIndex + 1] == 0x8B
        else { throw DebError.damaged("the gzip header is missing") }
        let flags = data[data.startIndex + 3]
        var cursor = 10
        if flags & 0x04 != 0 {                         // FEXTRA
            guard cursor + 2 <= data.count else { throw DebError.damaged("the gzip extra field is truncated") }
            let length = Int(data[data.startIndex + cursor])
                | Int(data[data.startIndex + cursor + 1]) << 8
            cursor += 2 + length
        }
        if flags & 0x08 != 0 {                         // FNAME
            while cursor < data.count, data[data.startIndex + cursor] != 0 { cursor += 1 }
            cursor += 1
        }
        if flags & 0x10 != 0 {                         // FCOMMENT
            while cursor < data.count, data[data.startIndex + cursor] != 0 { cursor += 1 }
            cursor += 1
        }
        if flags & 0x02 != 0 { cursor += 2 }           // FHCRC
        guard cursor < data.count else { throw DebError.damaged("the gzip body is empty") }
        let stream = data.subdata(in: (data.startIndex + cursor)..<data.endIndex)

        // The size isn't in the header, so inflate into a growing buffer.
        var capacity = max(1 << 16, min(stream.count * 4, limit))
        while capacity <= limit {
            var out = Data(count: capacity)
            let written = out.withUnsafeMutableBytes { dst -> Int in
                guard let target = dst.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return stream.withUnsafeBytes { src -> Int in
                    guard let source = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_decode_buffer(target, capacity, source, stream.count,
                                                     nil, COMPRESSION_ZLIB)
                }
            }
            // A full buffer means it may have been cut off; grow and retry.
            if written > 0 && written < capacity { return out.prefix(written) }
            capacity *= 2
        }
        throw DebError.damaged("it unpacks to more than \(limit / (1 << 20)) MB")
    }
}
