import Foundation

/// An Agent Skill bundled with AgentKit: a `SKILL.md` folder with YAML frontmatter (`name`,
/// `description`, optional `allowed-tools`).
public struct BundledSkill: Hashable, Sendable, Identifiable {
    public var name: String
    public var description: String
    public var allowedTools: String?
    public var directory: URL

    public var id: String { name }
}

/// Materialises the bundled `Skills/` folder into the runtime's working directory as
/// `.claude/skills/<name>/`, where Claude Code discovers them (metadata at startup, body on relevance).
public enum SkillsInstaller {
    public enum Failure: Error, Sendable { case bundleMissing }

    /// The `Skills` resource directory.
    public static var bundledDirectory: URL? { Bundle.module.url(forResource: "Skills", withExtension: nil) }

    /// Every bundled skill, sorted by name.
    public static func bundledSkills() throws -> [BundledSkill] {
        guard let root = bundledDirectory else { throw Failure.bundleMissing }
        return try skills(in: root)
    }

    /// The skills under `root` (one `SKILL.md` per subdirectory).
    public static func skills(in root: URL) throws -> [BundledSkill] {
        let entries = try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey])
        var result: [BundledSkill] = []
        for entry in entries {
            let skillFile = entry.appendingPathComponent("SKILL.md")
            guard let data = try? Data(contentsOf: skillFile), let text = String(data: data, encoding: .utf8) else {
                continue
            }
            let front = frontmatter(of: text)
            result.append(
                BundledSkill(
                    name: front["name"] ?? entry.lastPathComponent, description: front["description"] ?? "",
                    allowedTools: front["allowed-tools"], directory: entry))
        }
        return result.sorted { $0.name < $1.name }
    }

    /// Copies every bundled skill into `<workingDirectory>/.claude/skills/<name>/`, replacing what is
    /// there. Returns the installed skill directories.
    @discardableResult
    public static func install(into workingDirectory: URL) throws -> [URL] {
        guard let root = bundledDirectory else { throw Failure.bundleMissing }
        return try install(from: root, into: workingDirectory)
    }

    @discardableResult
    public static func install(from root: URL, into workingDirectory: URL) throws -> [URL] {
        let target = skillsDirectory(in: workingDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        var installed: [URL] = []
        for skill in try skills(in: root) {
            let destination = target.appendingPathComponent(skill.name, isDirectory: true)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: skill.directory, to: destination)
            installed.append(destination)
        }
        return installed
    }

    public static func skillsDirectory(in workingDirectory: URL) -> URL {
        workingDirectory.appendingPathComponent(".claude/skills", isDirectory: true)
    }

    /// The `key: value` pairs between the leading `---` lines.
    public static func frontmatter(of text: String) -> [String: String] {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [:] }
        lines.removeFirst()
        var result: [String: String] = [:]
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.first == "\"", value.last == "\"" {
                value = String(value.dropFirst().dropLast())
            }
            result[key] = value
        }
        return result
    }
}
