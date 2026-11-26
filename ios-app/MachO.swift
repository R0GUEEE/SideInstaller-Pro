import Foundation

/// The Mach-O header reader shared by the inspector and the patcher: what a
/// binary runs on, what iOS it was built for, and whether its code is encrypted.

/// The parts of a Mach-O header worth reading before an install: what it runs
/// on, what iOS it was built for, and whether its code is still encrypted.
struct MachOInfo {
    var archs: [String] = []
    var minimumOS: String?
    var encrypted = false
}

/// Reads the executable's own headers. Fat binaries are walked slice by slice,
/// so an x86_64 + arm64 build reports both — and still counts as arm64-capable.
func machO(_ data: Data) -> MachOInfo? {
    let bytes = [UInt8](data.prefix(64 << 20))
    guard bytes.count >= 28 else { return nil }
    switch bigEndian32(bytes, 0) {
    case 0xCAFE_BABE:
        return fatMachO(bytes, bigEndian: true, is64: false)
    case 0xCAFE_BABF:
        return fatMachO(bytes, bigEndian: true, is64: true)
    case 0xBEBA_FECA:
        return fatMachO(bytes, bigEndian: false, is64: false)
    case 0xBFBA_FECA:
        return fatMachO(bytes, bigEndian: false, is64: true)
    default:
        return thinMachO(bytes, 0)
    }
}

private func fatMachO(_ bytes: [UInt8], bigEndian: Bool, is64: Bool) -> MachOInfo? {
    let count = Int(read32(bytes, 4, bigEndian: bigEndian))
    guard count > 0, count < 64 else { return nil }
    let stride = is64 ? 32 : 20
    var out = MachOInfo()
    for index in 0..<count {
        let at = 8 + index * stride
        guard at + stride <= bytes.count else { break }
        let cpu = read32(bytes, at, bigEndian: bigEndian)
        let subtype = read32(bytes, at + 4, bigEndian: bigEndian)
        let offset = is64 ? Int(read64(bytes, at + 8, bigEndian: bigEndian))
                          : Int(read32(bytes, at + 8, bigEndian: bigEndian))
        out.archs.append(architecture(cpu: cpu, subtype: subtype))
        guard let slice = thinMachO(bytes, offset) else { continue }
        out.encrypted = out.encrypted || slice.encrypted
        if out.minimumOS == nil { out.minimumOS = slice.minimumOS }
    }
    return out.archs.isEmpty ? nil : out
}

private func thinMachO(_ bytes: [UInt8], _ base: Int) -> MachOInfo? {
    guard base >= 0, base + 28 <= bytes.count else { return nil }
    let magic = bigEndian32(bytes, base)
    let bigEndian: Bool
    let is64: Bool
    // The magic is read big-endian, so the byte order it comes back in says
    // how the file's own fields are stored: an iOS arm64 binary starts
    // `CF FA ED FE`, which is 0xCFFAEDFE here and little-endian inside.
    switch magic {
    case 0xCFFA_EDFE:   bigEndian = false; is64 = true      // MH_MAGIC_64 in a little-endian file
    case 0xCEFA_EDFE:   bigEndian = false; is64 = false     // MH_MAGIC
    case 0xFEED_FACF:   bigEndian = true;  is64 = true      // MH_MAGIC_64 in a big-endian file
    case 0xFEED_FACE:   bigEndian = true;  is64 = false     // MH_MAGIC
    default: return nil
    }
    let cpu = read32(bytes, base + 4, bigEndian: bigEndian)
    let subtype = read32(bytes, base + 8, bigEndian: bigEndian)
    let commandCount = Int(read32(bytes, base + 16, bigEndian: bigEndian))
    var out = MachOInfo(archs: [architecture(cpu: cpu, subtype: subtype)])
    var cursor = base + (is64 ? 32 : 28)
    // A hostile or corrupt file can claim thousands; the bound keeps this cheap.
    for _ in 0..<min(commandCount, 4096) {
        guard cursor + 8 <= bytes.count else { break }
        let command = read32(bytes, cursor, bigEndian: bigEndian)
        let size = Int(read32(bytes, cursor + 4, bigEndian: bigEndian))
        guard size >= 8, cursor + size <= bytes.count else { break }
        switch command {
        case 0x32:      // LC_BUILD_VERSION
            let platform = read32(bytes, cursor + 8, bigEndian: bigEndian)
            if out.minimumOS == nil, platform == 2 {            // PLATFORM_IOS
                out.minimumOS = versionText(read32(bytes, cursor + 12, bigEndian: bigEndian))
            }
        case 0x25:      // LC_VERSION_MIN_IPHONEOS
            if out.minimumOS == nil {
                out.minimumOS = versionText(read32(bytes, cursor + 8, bigEndian: bigEndian))
            }
        case 0x21, 0x2C:    // LC_ENCRYPTION_INFO, LC_ENCRYPTION_INFO_64
            if read32(bytes, cursor + 16, bigEndian: bigEndian) != 0 { out.encrypted = true }
        default:
            break
        }
        cursor += size
    }
    return out
}

/// `cputype`/`cpusubtype` as the arch name Xcode shows.
private func architecture(cpu: UInt32, subtype: UInt32) -> String {
    switch cpu {
    case 0x0100_000C:                                   // CPU_TYPE_ARM64
        // CPU_SUBTYPE_ARM64E is 2 with the pointer-authentication ABI bit.
        return (subtype & 0x00FF_FFFF) == 2 ? "arm64e" : "arm64"
    case 0x0200_000C: return "arm64_32"
    case 12:          return "armv7"
    case 0x0100_0007: return "x86_64"
    case 7:           return "i386"
    default:          return String(format: "cpu 0x%x", cpu)
    }
}

/// A `minos`/`version` field: xxxx.yy.zz packed into 32 bits.
private func versionText(_ value: UInt32) -> String {
    let major = value >> 16
    let minor = (value >> 8) & 0xFF
    let patch = value & 0xFF
    return patch == 0 ? "\(major).\(minor)" : "\(major).\(minor).\(patch)"
}

private func bigEndian32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
    guard at >= 0, at + 4 <= bytes.count else { return 0 }
    return UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16
        | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
}

private func read32(_ bytes: [UInt8], _ at: Int, bigEndian: Bool) -> UInt32 {
    let value = bigEndian32(bytes, at)
    return bigEndian ? value : value.byteSwapped
}

private func read64(_ bytes: [UInt8], _ at: Int, bigEndian: Bool) -> UInt64 {
    let high = read32(bytes, at, bigEndian: bigEndian)
    let low = read32(bytes, at + 4, bigEndian: bigEndian)
    return bigEndian ? UInt64(high) << 32 | UInt64(low) : UInt64(low) << 32 | UInt64(high)
}
