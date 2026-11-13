import Foundation

/// The lines of paddock's CLI that the launcher has a text for in every
/// language. paddock writes English. `UIText.cli` asks here.
///
/// A line is a catalog key as it is, or with `%@` where paddock puts a
/// value (a path, a size, a version), and `%lld` where it puts a count.
/// When paddock gets a new line, add it here and translate it in the
/// catalog. A line that is not here still shows: in English as it is, in
/// another language as the fallback sentence of its place, with the line
/// under "Details".
public enum CLIWords {
    /// Each line is written as a `UIText`, so `Scripts/strings.py` puts
    /// it in the catalog.
    static let lines: [UIText] = [
        // paddock doctor
        UIText("paddock-vm has the Virtualization entitlement."),
        UIText("%@ of %@ macOS VMs run."),
        UIText("%@ GiB: each app gets up to %@ GiB."),
        UIText("%@ GiB: each app gets %@ GiB, the minimum."),
        UIText("This Mac has Apple silicon (%@)."),
        UIText("This Mac has an Intel chip (%@). paddock app mode needs a Mac with Apple silicon."),
        UIText("macOS %@."),
        UIText("macOS %@. paddock app mode needs macOS %@ or newer: update macOS in System Settings."),
        UIText("%@ GiB free, %@ GiB needed."),
        UIText("%@ GiB free, %@ GiB needed. Free up %@ GiB on the disk of %@, then check again."),
        UIText("Build the base image first: paddock macvm setup."),
        // app add, app run, app list
        UIText("The golden image is not sealed. Run paddock macvm setup first."),
        UIText("Needs %@ on the volume of the macvm folder, %@ free."),
        UIText("%@ comes from the App Store and needs an Apple ID, which the guest does not have. Install the download from the maker's website into /Applications instead."),
        UIText("The bundle %@ is not found. Install the app again, or remove it from paddock."),
        UIText("Build the base image to start this app."),
        UIText("The VM stopped: out of memory"),
        UIText("crashed"),
        UIText("a third session needed the slot"),
        UIText("the first start of this profile"),
        UIText("the golden changed"),
        UIText("the app changed on this Mac"),
        UIText("macOS %@ (sealed)"),
        UIText("sealed"),
        UIText("paddock asks you the first time the app reaches a new server."),
        // macvm setup
        UIText("The download pauses."),
        UIText("The download is done; the install cannot pause."),
        UIText("This restore image does not run on this Mac."),
        UIText("The password was wrong three times."),
        UIText("The download of the restore image stopped: the connection closed."),
        UIText("The disk is full: the image needs %@, %@ is free."),
        // grants and rules
        UIText("Allow always %@"),
        UIText("Deny always %@"),
        UIText("%@ is private to this Mac and cannot be shared."),
        UIText("paddock refuses a rule for %@: the guest may not reach this Mac's local network."),
        UIText("%@ has a .env file. The app could read the keys in it."),
        // gc and du
        UIText("not used for %lld days"),
        UIText("in the trash for more than %lld days"),
        UIText("its project is gone"),
        UIText("the project %@ is gone"),
        UIText("the golden is sealed"),
        UIText("the sandbox ended without removing them; nothing was returned from them"),
        UIText("they rebuild themselves: %@"),
        UIText("its login is lost"),
        UIText("transcripts, history and settings of this project; the login stays in %@"),
        UIText("transcripts, history and settings of this project; the login stays in your host home"),
        UIText("restore image %@"),
        UIText("macvm trash: %@"),
        UIText("macvm profile %@"),
        UIText("snapshot %@ of %@"),
        UIText("pure caches in home %@"),
        UIText("home %@"),
        UIText("borrowed copies of %@ (%@)"),
    ]

    /// The formats, the most exact first: more fixed words win, so
    /// `macOS %@. paddock app mode needs…` comes before `macOS %@.`.
    static let formats: [String] = lines.map(\.key).sorted { fixed($0) > fixed($1) }

    private static func fixed(_ format: String) -> Int {
        shape(format).replacingOccurrences(of: "%@", with: "").count
    }

    /// The format with `%@` for each value, counts too.
    static func shape(_ format: String) -> String {
        format.replacingOccurrences(of: "%lld", with: "%@")
    }

    /// The places (from 0) of the counts of `format`.
    static func countPlaces(_ format: String) -> Set<Int> {
        var places: Set<Int> = []
        var rest = Substring(format)
        var place = 0
        while let range = rest.range(of: "%") {
            rest = rest[range.upperBound...]
            if rest.hasPrefix("@") {
                place += 1
            } else if rest.hasPrefix("lld") {
                places.insert(place)
                place += 1
            }
        }
        return places
    }

    /// The catalog text of `raw`, or nil for a line that is not known.
    public static func known(_ raw: String) -> UIText? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        for format in formats {
            guard let values = match(shape(format), line) else { continue }
            let counts = countPlaces(format)
            // A count is a whole number, for its plural form.
            if counts.contains(where: { $0 < values.count && Int(values[$0]) == nil }) { continue }
            return UIText(key: format, values: values.enumerated().map { place, value in
                counts.contains(place) ? .count(Int(value) ?? 0) : .string(value)
            })
        }
        return nil
    }

    /// The values of `line` when it has the shape of `format`: every fixed
    /// part in order, and a value that is not empty in each `%@`.
    static func match(_ format: String, _ line: String) -> [String]? {
        let parts = format.components(separatedBy: "%@")
        if parts.count == 1 { return format == line ? [] : nil }
        guard line.hasPrefix(parts[0]) else { return nil }
        var rest = line.dropFirst(parts[0].count)
        var values: [String] = []
        for (index, part) in parts.enumerated().dropFirst() {
            let last = index == parts.count - 1
            if part.isEmpty {
                // A value at the end of the line.
                guard last, !rest.isEmpty else { return nil }
                values.append(String(rest))
                rest = rest[rest.endIndex...]
                continue
            }
            // The last fixed part ends the line: look from the back.
            let found = last ? rest.range(of: part, options: [.backwards, .anchored]) : rest.range(of: part)
            guard let range = found, range.lowerBound > rest.startIndex else { return nil }
            values.append(String(rest[rest.startIndex..<range.lowerBound]))
            rest = rest[range.upperBound...]
        }
        return rest.isEmpty ? values : nil
    }

    /// The sentence for a line of paddock in a place that has no better
    /// one: it points to the "Details" disclosure.
    public static let seeDetails = UIText("paddock gave a reason. Open Details to read it.")
}
