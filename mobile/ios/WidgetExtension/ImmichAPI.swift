import Foundation
import SwiftUI
import WidgetKit

enum WidgetError: Error, Codable {
  case noLogin
  case fetchFailed
  case unknown
  case albumNotFound
  case unableToResize
  case invalidImage
  case invalidURL
}

extension WidgetError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .noLogin:
      return "Login to Immich"

    case .fetchFailed:
      return "Unable to connect to your Immich instance"

    case .albumNotFound:
      return "Album not found"

    case .invalidURL:
      return "An invalid URL was used"

    case .invalidImage:
      return "An invalid image was received"

    default:
      return "An unknown error occured"
    }
  }
}

enum AssetType: String, Codable {
  case image = "IMAGE"
  case video = "VIDEO"
  case audio = "AUDIO"
  case other = "OTHER"
}

struct Asset: Codable {
  let id: String
  let type: AssetType

  var deepLink: URL? {
    return URL(string: "immich://asset?id=\(id)")
  }
}

struct SearchFilters: Codable {
  var type: AssetType = .image
  let size: Int
  var albumIds: [String] = []
}

struct MemoryResult: Codable {
  let id: String
  var assets: [Asset]
  let type: String

  struct MemoryData: Codable {
    let year: Int
  }

  let data: MemoryData
}

struct Album: Codable {
  let id: String
  let albumName: String
}

let IMMICH_SHARE_GROUP = "group.app.immich.share"

// MARK: API

class ImmichAPI {
  struct ServerConfig {
    let serverEndpoint: String
    let sessionKey: String
  }
  let serverConfig: ServerConfig

  init() async throws {
    // fetch the credentials from the UserDefaults store that dart placed here
    guard let defaults = UserDefaults(suiteName: IMMICH_SHARE_GROUP),
      let serverURL = defaults.string(forKey: "widget_server_url"),
      let sessionKey = defaults.string(forKey: "widget_auth_token")
    else {
      throw WidgetError.noLogin
    }

    if serverURL == "" || sessionKey == "" {
      throw WidgetError.noLogin
    }

    serverConfig = ServerConfig(
      serverEndpoint: serverURL,
      sessionKey: sessionKey
    )
  }

  private func buildRequestURL(
    serverConfig: ServerConfig,
    endpoint: String,
    params: [URLQueryItem] = []
  ) -> URL? {
    guard let baseURL = URL(string: serverConfig.serverEndpoint) else {
      fatalError("Invalid base URL")
    }

    // Combine the base URL and API path
    let fullPath = baseURL.appendingPathComponent(
      endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    )

    // Add the session key as a query parameter
    var components = URLComponents(
      url: fullPath,
      resolvingAgainstBaseURL: false
    )
    components?.queryItems = [
      URLQueryItem(name: "sessionKey", value: serverConfig.sessionKey)
    ]
    components?.queryItems?.append(contentsOf: params)

    return components?.url
  }

  func fetchSearchResults(with filters: SearchFilters) async throws
    -> [Asset]
  {
    // get URL
    guard
      let searchURL = buildRequestURL(
        serverConfig: serverConfig,
        endpoint: "/search/random"
      )
    else {
      throw URLError(.badURL)
    }

    var request = URLRequest(url: searchURL)
    request.httpMethod = "POST"
    request.httpBody = try JSONEncoder().encode(filters)
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let (data, _) = try await URLSession.shared.data(for: request)

    // decode data
    return try JSONDecoder().decode([Asset].self, from: data)
  }

  func fetchMemory(for date: Date) async throws -> [MemoryResult] {
    // get URL
    let memoryParams = [URLQueryItem(name: "for", value: date.ISO8601Format())]
    guard
      let searchURL = buildRequestURL(
        serverConfig: serverConfig,
        endpoint: "/memories",
        params: memoryParams
      )
    else {
      throw URLError(.badURL)
    }

    var request = URLRequest(url: searchURL)
    request.httpMethod = "GET"

    let (data, _) = try await URLSession.shared.data(for: request)

    // decode data
    return try JSONDecoder().decode([MemoryResult].self, from: data)
  }

  func fetchImage(asset: Asset) async throws(WidgetError) -> UIImage {
    let thumbnailParams = [URLQueryItem(name: "size", value: "preview")]
    let assetEndpoint = "/assets/" + asset.id + "/thumbnail"

    guard
      let fetchURL = buildRequestURL(
        serverConfig: serverConfig,
        endpoint: assetEndpoint,
        params: thumbnailParams
      )
    else {
      throw .invalidURL
    }

    guard let imageSource = CGImageSourceCreateWithURL(fetchURL as CFURL, nil)
    else {
      throw .invalidURL
    }

    let decodeOptions: [NSString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: 400,
      kCGImageSourceCreateThumbnailWithTransform: true,
    ]

    guard
      let thumbnail = CGImageSourceCreateThumbnailAtIndex(
        imageSource,
        0,
        decodeOptions as CFDictionary
      )
    else {
      throw .fetchFailed
    }

    return UIImage(cgImage: thumbnail)
  }

  func fetchAlbums() async throws -> [Album] {
    // get URL
    guard
      let searchURL = buildRequestURL(
        serverConfig: serverConfig,
        endpoint: "/albums"
      )
    else {
      throw URLError(.badURL)
    }

    var request = URLRequest(url: searchURL)
    request.httpMethod = "GET"

    let (data, _) = try await URLSession.shared.data(for: request)

    // decode data
    return try JSONDecoder().decode([Album].self, from: data)
  }
}

// We need a shared cache for albums to efficiently handle the album picker queries
actor AlbumCache {
  static let shared = AlbumCache()

  private var api: ImmichAPI? = nil
  private var albums: [Album]? = nil

  func getAlbums(refresh: Bool = false) async throws -> [Album] {
    // Check the API before we try to show cached albums
    // Sometimes iOS caches this object and keeps it around
    // even after nuking the timeline

    api = try? await ImmichAPI()

    guard api != nil else {
      throw WidgetError.noLogin
    }

    if let albums, !refresh {
      return albums
    }

    let fetched = try await api!.fetchAlbums()
    albums = fetched
    return fetched
  }
}
