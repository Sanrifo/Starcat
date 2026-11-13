//
//  AwesomeReadmeParser.swift
//  Starcat
//
//  使用 Apple swift-markdown 的 CommonMark/GFM AST 解析 Awesome README。
//
//  解析器从列表项、引用块和表格行提取公开 GitHub 仓库，保留当时的章节、描述和顺序。
//  外部链接只计数，不尝试猜测其背后的 GitHub 项目。Repo 是否真实公开由后续 GitHub API
//  核验，解析器本身不把 URL 文本当成可信元数据。
//
//  Sanrifo/awesome-java 把每条项目写成 <details> 里的引用块，分类名在 <summary>，
//  不是 Markdown 列表。CommonMark 遇到空行就会结束 HTML block，所以引用块仍是 AST
//  节点；分类名留在 HTML 里，必须单独从 summary 取，否则整份清单会被当成空目录。
//

import Foundation
import Markdown

struct AwesomeRepositoryAddress: Hashable, Sendable {
    let owner: String
    let repo: String

    var fullName: String { "\(owner)/\(repo)" }
    var canonicalURL: URL { URL(string: "https://github.com/\(owner)/\(repo)")! }
}

enum AwesomeSourceInput {
    /// 接受 `owner/repo` 或 canonical GitHub 仓库 URL；子页面、非 HTTPS 和非 GitHub 域名拒绝。
    static func parse(_ raw: String) -> AwesomeRepositoryAddress? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") {
            return address(pathComponents: trimmed.split(separator: "/").map(String.init))
        }
        guard let url = URL(string: trimmed),
              url.scheme?.lowercased() == "https",
              ["github.com", "www.github.com"].contains(url.host?.lowercased() ?? "")
        else { return nil }
        return address(pathComponents: url.path.split(separator: "/").map(String.init))
    }

    private static func address(pathComponents: [String]) -> AwesomeRepositoryAddress? {
        guard pathComponents.count == 2 else { return nil }
        let owner = pathComponents[0]
        let repo = pathComponents[1].hasSuffix(".git")
            ? String(pathComponents[1].dropLast(4))
            : pathComponents[1]
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard !owner.isEmpty, !repo.isEmpty,
              owner.unicodeScalars.allSatisfy(allowed.contains),
              repo.unicodeScalars.allSatisfy(allowed.contains),
              owner != ".", owner != "..", repo != ".", repo != ".."
        else { return nil }
        return AwesomeRepositoryAddress(owner: owner, repo: repo)
    }
}

struct ParsedAwesomeLink: Hashable, Sendable {
    let address: AwesomeRepositoryAddress
    let title: String
    let description: String?
    let sectionPath: [String]
    let order: Int
    let sourceAnchorURL: URL
}

struct AwesomeReadmeParseResult: Equatable, Sendable {
    let githubLinks: [ParsedAwesomeLink]
    let externalLinkCount: Int
}

enum AwesomeReadmeParser {
    static let maximumMarkdownBytes = 5 * 1024 * 1024
    static let maximumEntries = 2_000

    static func parse(
        markdown: String,
        source: AwesomeRepositoryAddress,
        defaultBranch: String,
        readmePath: String = "README.md"
    ) throws -> AwesomeReadmeParseResult {
        guard markdown.utf8.count <= maximumMarkdownBytes else {
            throw AwesomeCustomSourceError.readmeTooLarge
        }
        let document = Document(parsing: markdown, options: [.parseBlockDirectives])
        var walker = AwesomeWalker(
            source: source,
            defaultBranch: defaultBranch,
            readmePath: readmePath
        )
        walker.visit(document)
        return AwesomeReadmeParseResult(
            githubLinks: Array(walker.links.prefix(maximumEntries)),
            externalLinkCount: walker.externalLinkCount
        )
    }
}

private struct DetailsFrame {
    let title: String?
    let anchorID: String?
    /// 打开 details 之前的 Markdown 标题。关闭时恢复，避免上一个分类的 #### 小标题漏到下一个分类。
    let headingsBefore: [Int: String]
}

private struct AwesomeWalker: MarkupWalker {
    let source: AwesomeRepositoryAddress
    let defaultBranch: String
    let readmePath: String
    var headings: [Int: String] = [:]
    var detailsStack: [DetailsFrame] = []
    var links: [ParsedAwesomeLink] = []
    var externalLinkCount = 0

    mutating func visitHeading(_ heading: Heading) {
        headings = headings.filter { $0.key < heading.level }
        let title = Self.cleanTitle(Self.visibleHeadingText(heading))
        if !title.isEmpty { headings[heading.level] = title }
        descendInto(heading)
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        for event in Self.detailsEvents(in: html.rawHTML) {
            switch event {
            case .close:
                guard let frame = detailsStack.popLast() else { continue }
                headings = frame.headingsBefore
            case let .open(title, anchorID):
                detailsStack.append(
                    DetailsFrame(title: title, anchorID: anchorID, headingsBefore: headings)
                )
            }
        }
    }

    mutating func visitListItem(_ listItem: ListItem) {
        recordEntries(in: listItem)
        // 嵌套列表、引用和表格由各自的 visit 记录。这里继续向下，才能走到子项。
        descendInto(listItem)
    }

    mutating func visitBlockQuote(_ blockQuote: BlockQuote) {
        recordEntries(in: blockQuote)
        descendInto(blockQuote)
    }

    mutating func visitTableRow(_ tableRow: Table.Row) {
        recordEntries(in: tableRow)
        descendInto(tableRow)
    }

    /// 一个容器只代表一个项目。第一条仓库链接是项目本身，后面的链接通常是文档、规范或顺带提到的仓库。
    private mutating func recordEntries(in container: Markup) {
        let content = EntryContent.collect(from: container)
        let sectionPath = currentSectionPath()
        var recordedGitHubLink = false

        for link in content.links {
            guard let destination = link.destination,
                  let url = URL(string: destination)
            else { continue }
            if Self.containsImage(link) { continue }
            switch Self.classify(url, source: source) {
            case .ignore:
                continue
            case .external:
                externalLinkCount += 1
                continue
            case let .repository(address):
                guard !recordedGitHubLink else { continue }
                recordedGitHubLink = true
                let title = link.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayTitle = title.isEmpty ? address.fullName : title
                links.append(
                    ParsedAwesomeLink(
                        address: address,
                        title: displayTitle,
                        description: Self.description(from: content, removing: displayTitle),
                        sectionPath: sectionPath,
                        order: links.count,
                        sourceAnchorURL: sourceAnchorURL(sectionPath: sectionPath)
                    )
                )
            }
        }
    }

    private func currentSectionPath() -> [String] {
        guard let first = detailsStack.first else {
            return Self.headingTitles(headings)
        }
        var path = Self.headingTitles(first.headingsBefore)
        for index in detailsStack.indices {
            if let title = detailsStack[index].title, !title.isEmpty {
                path.append(title)
            }
            let before = detailsStack[index].headingsBefore
            let after = index + 1 < detailsStack.count
                ? detailsStack[index + 1].headingsBefore
                : headings
            path.append(contentsOf: Self.headingDelta(from: before, to: after))
        }
        return path
    }

    private func sourceAnchorURL(sectionPath: [String]) -> URL {
        let base = "https://github.com/\(source.fullName)/blob/\(defaultBranch)/\(readmePath)"
        guard let heading = sectionPath.last else { return URL(string: base)! }
        // <details id="..."> 的 id 就是 GitHub 页面锚点。小标题没有 id，继续用标题 slug。
        let fragment: String
        if let frame = detailsStack.last,
           frame.title == heading,
           let anchorID = frame.anchorID,
           !anchorID.isEmpty {
            fragment = anchorID
        } else {
            fragment = Self.githubAnchor(heading)
        }
        guard !fragment.isEmpty else { return URL(string: base)! }
        return URL(string: "\(base)#\(fragment)") ?? URL(string: base)!
    }

    private static func headingTitles(_ headings: [Int: String]) -> [String] {
        headings.keys.sorted().compactMap { key in
            let title = headings[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return title?.isEmpty == false ? title : nil
        }
    }

    private static func headingDelta(from before: [Int: String], to after: [Int: String]) -> [String] {
        after.keys.sorted().compactMap { key in
            guard after[key] != before[key] else { return nil }
            let title = after[key]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return title?.isEmpty == false ? title : nil
        }
    }

    private static func description(from content: EntryContent, removing title: String) -> String? {
        var value = content.descriptionText
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        if !title.isEmpty, value.lowercased().hasPrefix(title.lowercased()) {
            value.removeFirst(min(title.count, value.count))
        }
        value = value.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: "-–—:："))
        )
        value = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return value.isEmpty ? nil : value
    }

    private static func githubAnchor(_ heading: String) -> String {
        var result = ""
        var previousWasHyphen = false
        for scalar in heading.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar.value > 127 {
                result.unicodeScalars.append(scalar)
                previousWasHyphen = false
            } else if scalar == " " || scalar == "-" {
                if !previousWasHyphen, !result.isEmpty { result.append("-") }
                previousWasHyphen = true
            }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// 标题里的徽章图片和 `<kbd>3 projects</kbd>` 不是章节名。
    private static func visibleHeadingText(_ markup: Markup) -> String {
        var parts: [String] = []
        func walk(_ node: Markup) {
            if node is Image { return }
            if let link = node as? Link, containsImage(link) { return }
            if node is InlineHTML { return }
            if node.childCount == 0, let plain = node as? PlainTextConvertibleMarkup {
                let value = plain.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { parts.append(value) }
                return
            }
            for child in node.children { walk(child) }
        }
        walk(markup)
        return parts.joined(separator: " ")
    }

    private static func cleanTitle(_ raw: String) -> String {
        var value = raw.replacingOccurrences(
            of: #"<[^>]+>"#,
            with: " ",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: #"\s+\d[\d,.]*\s+(projects?|links?|resources?)\s*$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        return value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func containsImage(_ markup: Markup) -> Bool {
        if markup is Image { return true }
        for child in markup.children where containsImage(child) { return true }
        return false
    }

    private enum GitHubLinkClassification {
        case repository(AwesomeRepositoryAddress)
        case external
        case ignore
    }

    private enum DetailsEvent {
        case open(title: String?, anchorID: String?)
        case close
    }

    /// `<details>` 在 CommonMark 里只延续到下一个空行，关闭标签通常是另一块 HTML。
    /// 按出现顺序处理，避免 `</details>` 和下一节 `<details>` 被拆开时丢章节。
    private static func detailsEvents(in rawHTML: String) -> [DetailsEvent] {
        var events: [DetailsEvent] = []
        var searchStart = rawHTML.startIndex
        while searchStart < rawHTML.endIndex,
              let bracket = rawHTML[searchStart...].firstIndex(of: "<") {
            let rest = rawHTML[bracket...]
            let lowered = rest.prefix(12).lowercased()
            if lowered.hasPrefix("</details") {
                events.append(.close)
            } else if lowered.hasPrefix("<details") {
                let tagEnd = rest.firstIndex(of: ">") ?? rawHTML.index(before: rawHTML.endIndex)
                let tag = String(rawHTML[bracket...tagEnd])
                let blockEnd = rawHTML[tagEnd...].range(of: "</details", options: .caseInsensitive)?.lowerBound
                    ?? rawHTML.endIndex
                let body = String(rawHTML[tagEnd..<blockEnd])
                events.append(.open(title: summaryTitle(in: body), anchorID: detailsID(in: tag)))
            }
            searchStart = rawHTML.index(after: bracket)
        }
        return events
    }

    private static func summaryTitle(in html: String) -> String? {
        guard let open = html.range(of: "<summary", options: .caseInsensitive),
              let tagEnd = html[open.upperBound...].firstIndex(of: ">"),
              let close = html.range(
                of: "</summary>",
                options: .caseInsensitive,
                range: html.index(after: tagEnd)..<html.endIndex
              )
        else { return nil }
        let title = cleanTitle(String(html[html.index(after: tagEnd)..<close.lowerBound]))
        return title.isEmpty ? nil : title
    }

    private static func detailsID(in tag: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?i)\bid\s*=\s*(?:"([^"]+)"|'([^']+)')"#
        ) else { return nil }
        let range = NSRange(tag.startIndex..., in: tag)
        guard let match = regex.firstMatch(in: tag, range: range) else { return nil }
        for group in 1...2 {
            let found = match.range(at: group)
            guard found.location != NSNotFound, let textRange = Range(found, in: tag) else { continue }
            let value = String(tag[textRange])
            if !value.isEmpty { return value }
        }
        return nil
    }

    private static func classify(
        _ url: URL,
        source: AwesomeRepositoryAddress
    ) -> GitHubLinkClassification {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return .ignore
        }
        guard let host = url.host?.lowercased(),
              host == "github.com" || host == "www.github.com"
        else { return .external }

        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return .external }
        let route = parts.count > 2 ? parts[2].lowercased() : nil
        if let route, route != "blob", route != "tree" { return .external }

        var repo = parts[1]
        if repo.lowercased().hasSuffix(".git") { repo = String(repo.dropLast(4)) }
        guard isRepositoryPart(parts[0]), isRepositoryPart(repo) else { return .external }
        if reservedGitHubOwners.contains(parts[0].lowercased()) { return .external }
        if parts[0].caseInsensitiveCompare(source.owner) == .orderedSame,
           repo.caseInsensitiveCompare(source.repo) == .orderedSame {
            return .ignore
        }
        return .repository(AwesomeRepositoryAddress(owner: parts[0], repo: repo))
    }

    private static let reservedGitHubOwners: Set<String> = [
        "features", "marketplace", "orgs", "settings", "sponsors", "topics",
    ]

    private static func isRepositoryPart(_ value: String) -> Bool {
        guard !value.isEmpty, value != ".", value != ".." else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }
}

private struct EntryContent {
    private struct Segment {
        enum Kind { case text, lineBreak }
        let kind: Kind
        let text: String
    }

    private var linksStorage: [Link] = []
    private var segments: [Segment] = []

    var links: [Link] { linksStorage }

    /// `<br>` 后面才是项目简介。星数、协议和活跃度都写在 `<br>` 前面，不能混进描述。
    var descriptionText: String {
        let source: ArraySlice<Segment>
        if let breakIndex = segments.lastIndex(where: { $0.kind == .lineBreak }) {
            source = segments[segments.index(after: breakIndex)...]
        } else {
            source = segments[...]
        }
        return source
            .filter { $0.kind == .text }
            .map(\.text)
            .joined(separator: " ")
    }

    static func collect(from container: Markup) -> EntryContent {
        var result = EntryContent()
        for child in container.children {
            collect(markup: child, into: &result)
        }
        return result
    }

    private static func collect(markup: Markup, into result: inout EntryContent) {
        if markup is ListItem || markup is BlockQuote || markup is Table || markup is Table.Row {
            return
        }
        if let link = markup as? Link {
            result.linksStorage.append(link)
        }
        if markup is Image { return }
        if let html = markup as? InlineHTML {
            if html.rawHTML.range(of: #"<br\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
                result.segments.append(Segment(kind: .lineBreak, text: ""))
            }
            return
        }
        if markup.childCount == 0, let plain = markup as? PlainTextConvertibleMarkup {
            let value = plain.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { result.segments.append(Segment(kind: .text, text: value)) }
        }
        for child in markup.children {
            collect(markup: child, into: &result)
        }
    }
}
