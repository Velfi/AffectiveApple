import Foundation
import NaturalLanguage

enum HostEmbeddingError: Error {
  case sentenceEmbeddingUnavailable
  case emptyBatch
}

struct HostEmbeddingRequest: Decodable {
  let texts: [String]
}

struct HostEmbeddingResponse: Encodable {
  let dimensions: Int
  let vectors: [[Double]]
}

enum HostEmbeddingClient {
  static let dimensions = 512

  static func computeEmbeddings(for texts: [String]) throws -> HostEmbeddingResponse {
    guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else {
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

  static func encodedResponse(for texts: [String]) throws -> Data {
    try JSONEncoder().encode(try computeEmbeddings(for: texts))
  }
}
