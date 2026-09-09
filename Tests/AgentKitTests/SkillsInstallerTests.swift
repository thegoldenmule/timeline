import Foundation
import Testing

@testable import AgentKit

@Suite struct SkillsInstallerTests {
    @Test func bundledSkillsSequenceTheTools() throws {
        let skills = try SkillsInstaller.bundledSkills()
        #expect(
            skills.map(\.name) == ["jump-cut-talking-head", "publish-to-youtube", "sync-daw-mix", "tiktok-captions"])
        for skill in skills {
            #expect(!skill.description.isEmpty && skill.allowedTools == "mcp__timeline__*")
            let body = try String(contentsOf: skill.directory.appendingPathComponent("SKILL.md"), encoding: .utf8)
            #expect(body.contains("project_describe"), "\(skill.name) reads the project")
            let mentioned = EditorTools.names.filter { body.contains("`\($0)`") }
            #expect(mentioned.count >= 3, "\(skill.name) sequences at least three tools: \(mentioned)")
        }
    }

    @Test func installsIntoTheWorkingDirectory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("agentkit-skills-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let installed = try SkillsInstaller.install(into: dir)
        #expect(installed.count == 4)
        #expect(installed.allSatisfy { $0.path.contains("/.claude/skills/") })
        for url in installed {
            #expect(FileManager.default.fileExists(atPath: url.appendingPathComponent("SKILL.md").path))
        }
        let again = try SkillsInstaller.install(into: dir)
        #expect(again.count == 4)
        let reread = try SkillsInstaller.skills(in: SkillsInstaller.skillsDirectory(in: dir))
        #expect(
            reread.map(\.name) == ["jump-cut-talking-head", "publish-to-youtube", "sync-daw-mix", "tiktok-captions"])
    }

    @Test func frontmatterParsing() {
        let text = "---\nname: x\ndescription: \"Quoted: value\"\nallowed-tools: a, b\n---\n# Body\nname: not this\n"
        let front = SkillsInstaller.frontmatter(of: text)
        #expect(front == ["name": "x", "description": "Quoted: value", "allowed-tools": "a, b"])
        #expect(SkillsInstaller.frontmatter(of: "# no front").isEmpty)
    }
}
