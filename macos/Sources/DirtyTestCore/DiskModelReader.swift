import Foundation
import IOKit
import Darwin

/// BSD device base name (e.g. "disk2") derived from a filesystem path.
public func bsdBaseName(forPath path: String) -> String? {
    var st = statfs()
    guard statfs(path, &st) == 0 else { return nil }

    let devPath = withUnsafePointer(to: st.f_mntfromname) { ptr -> String in
        String(cString: UnsafeRawPointer(ptr).assumingMemoryBound(to: CChar.self))
    }

    let name = devPath.replacingOccurrences(of: "/dev/", with: "")
    // Normalise: "disk2s1s1" -> "disk2", "disk10s3" -> "disk10"
    if let range = name.range(of: #"^disk\d+"#, options: .regularExpression) {
        return String(name[range])
    }
    return name.isEmpty ? nil : name
}

/// Walk the IOKit registry upward from the IOMedia node identified by *bsdName*
/// and return the first Product Name / Model string found on a parent node.
public func readDiskModel(bsdName: String) -> String? {
    for candidate in resolvedBSDCandidates(startingAt: bsdName) {
        if let model = readDiskModelViaDiskUtil(bsdName: candidate) {
            return model
        }
        if let model = readDiskModelViaIOKit(bsdName: candidate) {
            return model
        }
    }

    return nil
}

/// Convenience overload that derives the BSD name from a filesystem path first.
public func readDiskModel(forPath path: String) -> String? {
    guard let bsdName = bsdBaseName(forPath: path) else { return nil }
    return readDiskModel(bsdName: bsdName)
}

private func readDiskModelViaIOKit(bsdName: String) -> String? {
    guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else { return nil }

    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iter) }

    let leaf = IOIteratorNext(iter)
    guard leaf != IO_OBJECT_NULL else { return nil }

    // Walk up: IOMedia -> IOBlockStorageDriver -> IOBlockStorageDevice (holds model)
    var current: io_registry_entry_t = leaf
    while current != IO_OBJECT_NULL {
        for key in ["Product Name", "Model", "device-model", "Vendor Name"] {
            if let model = ioStringProperty(entry: current, key: key), isMeaningfulModelName(model) {
                IOObjectRelease(current)
                return model
            }
        }
        var parent: io_registry_entry_t = IO_OBJECT_NULL
        let status = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
        IOObjectRelease(current)
        current = (status == KERN_SUCCESS) ? parent : IO_OBJECT_NULL
    }
    return nil
}

// MARK: – Helpers

private func resolvedBSDCandidates(startingAt bsdName: String) -> [String] {
    var candidates = [normalizedBSDName(bsdName)]

    if let info = diskInfoPlist(forBSDName: bsdName) {
        if let stores = info["APFSPhysicalStores"] as? [[String: Any]] {
            for store in stores {
                if let physicalStore = store["APFSPhysicalStore"] as? String {
                    candidates.append(normalizedBSDName(physicalStore))
                }
            }
        }

        if let parentWholeDisk = info["ParentWholeDisk"] as? String {
            candidates.append(normalizedBSDName(parentWholeDisk))
        }
    }

    var seen = Set<String>()
    return candidates.filter { seen.insert($0).inserted }
}

private func readDiskModelViaDiskUtil(bsdName: String) -> String? {
    guard let info = diskInfoPlist(forBSDName: bsdName) else { return nil }

    if let mediaName = info["MediaName"] as? String, isMeaningfulModelName(mediaName) {
        return mediaName
    }

    if let deviceName = info["Device / Media Name"] as? String, isMeaningfulModelName(deviceName) {
        return deviceName
    }

    if let registryName = info["IORegistryEntryName"] as? String, isMeaningfulModelName(registryName) {
        return registryName
    }

    return nil
}

private func diskInfoPlist(forBSDName bsdName: String) -> [String: Any]? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
    process.arguments = ["info", "-plist", bsdName]

    let outputPipe = Pipe()
    process.standardOutput = outputPipe
    process.standardError = Pipe()

    do {
        try process.run()
    } catch {
        return nil
    }

    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }

    let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
    guard !data.isEmpty else { return nil }

    return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
}

private func normalizedBSDName(_ rawName: String) -> String {
    if let range = rawName.range(of: #"^disk\d+"#, options: .regularExpression) {
        return String(rawName[range])
    }
    return rawName
}

private func isMeaningfulModelName(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }

    let weakNames: Set<String> = [
        "unknown",
        "generic",
        "massstorageclass",
        "appleapfsmedia"
    ]

    return !weakNames.contains(trimmed.lowercased())
}

private func ioStringProperty(entry: io_registry_entry_t, key: String) -> String? {
    guard let cfVal = IORegistryEntryCreateCFProperty(
        entry, key as CFString, kCFAllocatorDefault, 0
    )?.takeRetainedValue() else { return nil }

    if let data = cfVal as? Data {
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .init(charactersIn: "\0").union(.whitespacesAndNewlines))
    }
    if let str = cfVal as? String {
        return str.trimmingCharacters(in: .init(charactersIn: "\0").union(.whitespacesAndNewlines))
    }
    return nil
}
