//
//  GitHubReleaseAssetDownloader.swift
//  HermitFlow
//
//  Minimal download helper that saves a GitHub release asset locally and opens it.
//

import AppKit
import Foundation

struct GitHubReleaseAssetDownloader: @unchecked Sendable {
    enum DownloadError: LocalizedError {
        case invalidHTTPResponse
        case httpError(Int)
        case missingSuggestedFilename
        case failedToMoveDownloadedFile

        var errorDescription: String? {
            switch self {
            case .invalidHTTPResponse:
                return "The update download returned an invalid response."
            case let .httpError(statusCode):
                return "The update download failed with HTTP \(statusCode)."
            case .missingSuggestedFilename:
                return "The downloaded update did not provide a valid file name."
            case .failedToMoveDownloadedFile:
                return "The downloaded update could not be prepared locally."
            }
        }
    }

    private let session: URLSession
    private let fileManager: FileManager

    init(
        session: URLSession = .shared,
        fileManager: FileManager = .default
    ) {
        self.session = session
        self.fileManager = fileManager
    }

    func downloadAsset(from remoteURL: URL) async throws -> URL {
        var request = URLRequest(url: remoteURL)
        request.setValue("HermitFlow", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60

        let (temporaryURL, response) = try await session.download(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DownloadError.invalidHTTPResponse
        }

        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            throw DownloadError.httpError(httpResponse.statusCode)
        }

        let suggestedFilename = httpResponse.suggestedFilename?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackFilename = remoteURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let filename = !(suggestedFilename ?? "").isEmpty ? suggestedFilename! : fallbackFilename
        guard !filename.isEmpty else {
            throw DownloadError.missingSuggestedFilename
        }

        let downloadsDirectory = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        let destinationDirectory = downloadsDirectory.appendingPathComponent(
            "HermitFlow",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: destinationDirectory,
            withIntermediateDirectories: true
        )

        let destinationURL = destinationDirectory.appendingPathComponent(filename, isDirectory: false)
        if fileManager.fileExists(atPath: destinationURL.path) {
            try? fileManager.removeItem(at: destinationURL)
        }

        do {
            try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        } catch {
            throw DownloadError.failedToMoveDownloadedFile
        }

        return destinationURL
    }

    func openDownloadedAsset(at localURL: URL) {
        NSWorkspace.shared.open(localURL)
    }
}
