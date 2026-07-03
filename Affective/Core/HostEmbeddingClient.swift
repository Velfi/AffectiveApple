import Foundation
import NaturalLanguage

enum HostEmbeddingError: Error {
  case sentenceEmbeddingUnavailable
  case emptyBatch
}

nonisolated struct HostEmbeddingRequest: Decodable {
  let texts: [String]
}

nonisolated struct HostEmbeddingResponse: Encodable {
  let dimensions: Int
  let vectors: [[Double]]
}

nonisolated enum HostEmbeddingClient {
  static let dimensions = 512

  private static let queueKey = DispatchSpecificKey<UInt8>()
  private static let queueKeyValue: UInt8 = 1
  private static let queue: DispatchQueue = {
    let queue = DispatchQueue(label: "com.zelda-built-this.AMBI.host-embedding", qos: .userInitiated)
    queue.setSpecific(key: queueKey, value: queueKeyValue)
    return queue
  }()

  /// NaturalLanguage loads a large sentence model; keep one instance for the process.
  private final class SentenceEmbeddingCache: @unchecked Sendable {
    static let shared = SentenceEmbeddingCache()
    let embedding = NLEmbedding.sentenceEmbedding(for: .english)
  }

  static func computeEmbeddings(for texts: [String]) throws -> HostEmbeddingResponse {
    try runOnQueue {
      guard let embedding = SentenceEmbeddingCache.shared.embedding else {
        throw HostEmbeddingError.sentenceEmbeddingUnavailable
      }
      guard !texts.isEmpty else { throw HostEmbeddingError.emptyBatch }

      let vectors = try texts.map { text -> [Double] in
        guard let vector = embedding.vector(for: text) else {
          throw HostEmbeddingError.sentenceEmbeddingUnavailable
        }
        if vector.count == dimensions {
          return vector
        }
        var padded = Array(repeating: 0.0, count: dimensions)
        for (index, value) in vector.enumerated() where index < dimensions {
          padded[index] = Double(value)
        }
        return padded
      }

      return HostEmbeddingResponse(dimensions: dimensions, vectors: vectors)
    }
  }

  static func encodedResponse(for texts: [String]) throws -> Data {
    try JSONEncoder().encode(try computeEmbeddings(for: texts))
  }

  private static func runOnQueue<T>(_ work: () throws -> T) throws -> T {
    if DispatchQueue.getSpecific(key: queueKey) == queueKeyValue {
      return try work()
    }
    return try queue.sync { try work() }
  }
}
