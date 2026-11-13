//
//  RepositoryMarkdownDocumentStack.swift
//  Starcat
//
//  详情框里打开的同仓 Markdown 栈。默认 README 不进这里。
//
//  语言文件不能写进 `readmes`：那张表按仓库一对一缓存，写进去会把默认 README、
//  翻译和 AI 上下文一起换掉。栈只活在当前详情会话里。
//

import Foundation

struct RepositoryMarkdownFrame: Equatable, Identifiable, Sendable {
    let target: RepositoryMarkdownLinkTarget
    let html: String

    var id: String { target.cacheKey }
}

struct RepositoryMarkdownDocumentStack: Equatable, Sendable {
    private(set) var frames: [RepositoryMarkdownFrame] = []

    var top: RepositoryMarkdownFrame? { frames.last }
    var isEmpty: Bool { frames.isEmpty }
    var currentPath: String? { top?.target.path }

    /// 同一路径再打开时替换栈顶，避免「返回」还要再经过同一份文件。
    mutating func push(_ frame: RepositoryMarkdownFrame) {
        if let index = frames.indices.last, frames[index].target == frame.target {
            frames[index] = frame
            return
        }
        frames.append(frame)
    }

    mutating func pop() {
        guard !frames.isEmpty else { return }
        frames.removeLast()
    }

    mutating func clear() {
        frames.removeAll()
    }
}
