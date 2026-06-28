import Foundation
import SQLite3

nonisolated protocol FaceRecognizing {
  func identify(_ request: FaceRecognitionIdentifyRequest) throws -> FaceRecognitionIdentityResult
  func enroll(_ request: FaceRecognitionEnrollRequest) throws -> FaceRecognitionEnrollResult
}

nonisolated struct FaceRecognitionIdentifyRequest: Decodable {
  let imagePath: String
  let memoryPath: String
  let embeddingsDir: String
  let detectorModel: String?
  let recognizerModel: String?
  let knownThreshold: Float
  let uncertainThreshold: Float

  enum CodingKeys: String, CodingKey {
    case imagePath = "image_path"
    case memoryPath = "memory_path"
    case embeddingsDir = "embeddings_dir"
    case detectorModel = "detector_model"
    case recognizerModel = "recognizer_model"
    case knownThreshold = "known_threshold"
    case uncertainThreshold = "uncertain_threshold"
  }
}

nonisolated struct FaceRecognitionEnrollRequest: Decodable {
  let imagePath: String
  let memoryPath: String
  let embeddingsDir: String
  let detectorModel: String?
  let recognizerModel: String?
  let personID: String?
  let name: String?
  let keepExisting: Bool

  enum CodingKeys: String, CodingKey {
    case imagePath = "image_path"
    case memoryPath = "memory_path"
    case embeddingsDir = "embeddings_dir"
    case detectorModel = "detector_model"
    case recognizerModel = "recognizer_model"
    case personID = "person_id"
    case name
    case keepExisting = "keep_existing"
  }
}

nonisolated struct FaceRecognitionIdentityResult: Encodable {
  let personPresent: Bool
  let matchStatus: String
  let personID: String?
  let confidence: Float
  let candidateName: String?
  let peopleCount: Int

  enum CodingKeys: String, CodingKey {
    case personPresent = "person_present"
    case matchStatus = "match_status"
    case personID = "person_id"
    case confidence
    case candidateName = "candidate_name"
    case peopleCount = "people_count"
  }
}

nonisolated struct FaceRecognitionEnrollResult: Encodable {
  let personID: String
  let displayName: String?
  let representativeImagePath: String
  let embeddingPath: String
  let qualityScore: Float
  let removedEmbeddings: Int
  let keptExisting: Bool

  enum CodingKeys: String, CodingKey {
    case personID = "person_id"
    case displayName = "display_name"
    case representativeImagePath = "representative_image_path"
    case embeddingPath = "embedding_path"
    case qualityScore = "quality_score"
    case removedEmbeddings = "removed_embeddings"
    case keptExisting = "kept_existing"
  }
}

nonisolated final class FaceRecognitionService: FaceRecognizing {
  private let bridge = AFFaceRecognitionBridge()
  private let fileManager: FileManager

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  static var bundledModelsAvailable: Bool {
    bundledModelPath("face_detection_yunet_2023mar_int8", extension: "onnx") != nil
      && bundledModelPath("face_recognition_sface_2021dec_int8", extension: "onnx") != nil
  }

  func identify(_ request: FaceRecognitionIdentifyRequest) throws -> FaceRecognitionIdentityResult {
    let embedding = try embedding(
      imagePath: request.imagePath,
      detectorModel: request.detectorModel,
      recognizerModel: request.recognizerModel
    )
    if embedding.faceCount == 0 {
      return .init(personPresent: false, matchStatus: "none", personID: nil, confidence: 0, candidateName: nil, peopleCount: 0)
    }
    if embedding.faceCount > 1 {
      return .init(personPresent: true, matchStatus: "multiple", personID: nil, confidence: 0, candidateName: nil, peopleCount: embedding.faceCount)
    }

    let memory = try CognitiveMemory.load(from: URL(fileURLWithPath: request.memoryPath))
    var best: (personID: String, displayName: String?, confidence: Float)?
    for subject in memory.activeSubjects {
      for candidate in try embeddings(
        for: subject,
        embeddingsDir: URL(fileURLWithPath: request.embeddingsDir)
      ) {
        let confidence = Self.confidence(fromSimilarity: Self.cosine(embedding.values, candidate))
        if best == nil || confidence > best!.confidence {
          best = (subject.personID, subject.displayName, confidence)
        }
      }
    }

    guard let best else {
      return .init(personPresent: true, matchStatus: "unknown", personID: nil, confidence: 0, candidateName: nil, peopleCount: 1)
    }

    let status: String
    if best.confidence >= request.knownThreshold {
      status = "known"
    } else if best.confidence >= request.uncertainThreshold {
      status = "uncertain"
    } else {
      status = "unknown"
    }
    return .init(
      personPresent: true,
      matchStatus: status,
      personID: status == "known" || status == "uncertain" ? best.personID : nil,
      confidence: best.confidence,
      candidateName: status == "known" || status == "uncertain" ? best.displayName : nil,
      peopleCount: 1
    )
  }

  func enroll(_ request: FaceRecognitionEnrollRequest) throws -> FaceRecognitionEnrollResult {
    guard request.personID != nil || request.name != nil else {
      throw FaceRecognitionError.invalidRequest("provide person_id or name")
    }
    let embedding = try embedding(
      imagePath: request.imagePath,
      detectorModel: request.detectorModel,
      recognizerModel: request.recognizerModel
    )
    guard embedding.faceCount == 1 else {
      throw FaceRecognitionError.invalidRequest("expected exactly one face in \(request.imagePath); found \(embedding.faceCount)")
    }

    var memory = try CognitiveMemory.load(from: URL(fileURLWithPath: request.memoryPath))
    let index = try memory.subjectIndex(personID: request.personID, name: request.name)
    let subject = CognitiveSubject(raw: memory.subjects[index])
    let personDir = URL(fileURLWithPath: request.embeddingsDir).appendingPathComponent(subject.personID, isDirectory: true)
    try fileManager.createDirectory(at: personDir, withIntermediateDirectories: true)

    let removed = request.keepExisting ? 0 : try removeCachedEmbeddings(in: personDir)
    let createdAt = String(Int(Date().timeIntervalSince1970))
    let imageStem = Self.safeStem(URL(fileURLWithPath: request.imagePath))
    let cacheURL = personDir.appendingPathComponent("manual_\(imageStem)_\(createdAt).npy")
    try NPY.write(embedding.values, to: cacheURL)

    var updatedSubject = subject.raw
    let existingRecords = subject.biometricRecords
    let nextID = "emb_\(existingRecords.count + 1)"
    let ref: [String: Any] = [
      "embedding_id": nextID,
      "quality_score": embedding.detectionScore,
      "created_at": createdAt,
      "source": "manual_merge",
    ]
    updatedSubject["biometric_records"] = request.keepExisting ? existingRecords + [ref] : [ref]
    updatedSubject.removeValue(forKey: "embeddings")
    updatedSubject["representative_image_path"] = request.imagePath
    updatedSubject["representative_quality_score"] = embedding.detectionScore
    var lifecycle = updatedSubject["lifecycle"] as? [String: Any] ?? [:]
    lifecycle["updated_at"] = createdAt
    updatedSubject["lifecycle"] = lifecycle
    memory.subjects[index] = updatedSubject
    try memory.save(to: URL(fileURLWithPath: request.memoryPath))

    return .init(
      personID: subject.personID,
      displayName: subject.displayName,
      representativeImagePath: request.imagePath,
      embeddingPath: cacheURL.path,
      qualityScore: embedding.detectionScore,
      removedEmbeddings: removed,
      keptExisting: request.keepExisting
    )
  }

  private func embedding(imagePath: String, detectorModel: String?, recognizerModel: String?) throws -> FaceEmbedding {
    let detectorPath = try Self.resolveModelPath(detectorModel, name: "face_detection_yunet_2023mar_int8")
    let recognizerPath = try Self.resolveModelPath(recognizerModel, name: "face_recognition_sface_2021dec_int8")
    let result = try bridge.embeddingForImage(
      atPath: imagePath,
      detectorModel: detectorPath,
      recognizerModel: recognizerPath
    )
    return FaceEmbedding(
      faceCount: result.faceCount,
      detectionScore: Float(result.detectionScore),
      values: result.embedding.map { Float(truncating: $0) }
    )
  }

  private func embeddings(
    for subject: CognitiveSubject,
    embeddingsDir: URL
  ) throws -> [[Float]] {
    let personDir = embeddingsDir.appendingPathComponent(subject.personID, isDirectory: true)
    guard fileManager.fileExists(atPath: personDir.path), !subject.biometricRecords.isEmpty else { return [] }
    let urls = try fileManager.contentsOfDirectory(
      at: personDir,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ).filter { $0.pathExtension == "npy" }.sorted { $0.path < $1.path }
    return try urls.map { try Self.normalized(NPY.read(from: $0)) }
  }

  private func removeCachedEmbeddings(in directory: URL) throws -> Int {
    guard fileManager.fileExists(atPath: directory.path) else { return 0 }
    let urls = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "npy" }
    for url in urls {
      try fileManager.removeItem(at: url)
    }
    return urls.count
  }

  private static func resolveModelPath(_ explicit: String?, name: String) throws -> String {
    if let explicit, !explicit.isEmpty, FileManager.default.fileExists(atPath: explicit) {
      return explicit
    }
    if let path = bundledModelPath(name, extension: "onnx") {
      return path
    }
    throw FaceRecognitionError.missingModel(name)
  }

  private static func bundledModelPath(_ name: String, extension ext: String) -> String? {
    Bundle.main.path(forResource: name, ofType: ext, inDirectory: "Recognition")
      ?? Bundle.main.path(forResource: name, ofType: ext, inDirectory: "Resources/Recognition")
      ?? Bundle.main.path(forResource: name, ofType: ext)
  }

  private static func cosine(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return -1 }
    return zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
  }

  private static func confidence(fromSimilarity similarity: Float) -> Float {
    max(0, min(1, (similarity + 1) / 2))
  }

  private static func normalized(_ values: [Float]) throws -> [Float] {
    let norm = sqrt(values.reduce(Float(0)) { $0 + $1 * $1 })
    guard norm.isFinite, norm > 0 else {
      throw FaceRecognitionError.invalidEmbedding("empty cached embedding")
    }
    return values.map { $0 / norm }
  }

  private static func safeStem(_ url: URL) -> String {
    let value = url.deletingPathExtension().lastPathComponent
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: "\\", with: "_")
      .replacingOccurrences(of: " ", with: "_")
    return value.isEmpty ? "image" : value
  }
}

nonisolated private struct FaceEmbedding {
  let faceCount: Int
  let detectionScore: Float
  let values: [Float]
}

nonisolated private enum FaceRecognitionError: Error, CustomStringConvertible {
  case invalidRequest(String)
  case missingModel(String)
  case invalidMemory(String)
  case invalidEmbedding(String)
  case sqlite(String)

  var description: String {
    switch self {
    case .invalidRequest(let message): return message
    case .missingModel(let name): return "missing recognition model: \(name).onnx"
    case .invalidMemory(let message): return message
    case .invalidEmbedding(let message): return message
    case .sqlite(let message): return message
    }
  }
}

nonisolated private struct CognitiveSubject {
  let raw: [String: Any]

  var personID: String {
    (raw["subject_id"] as? String) ?? (raw["person_id"] as? String) ?? ""
  }

  var displayName: String? {
    raw["display_name"] as? String
  }

  var relationshipStatus: String {
    raw["relationship_status"] as? String ?? "unknown"
  }

  var representativeImagePath: String? {
    raw["representative_image_path"] as? String
  }

  var embeddings: [[String: Any]] {
    biometricRecords
  }

  var biometricRecords: [[String: Any]] {
    raw["biometric_records"] as? [[String: Any]] ?? []
  }
}

nonisolated private struct CognitiveMemory {
  var data: [String: Any]
  var subjects: [[String: Any]]

  var activeSubjects: [CognitiveSubject] {
    subjects.map(CognitiveSubject.init(raw:)).filter {
      !$0.personID.isEmpty && $0.relationshipStatus != "forgotten"
    }
  }

  static func load(from url: URL) throws -> CognitiveMemory {
    try ensureSchema(at: url)
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
      throw FaceRecognitionError.sqlite("could not open memory database: \(url.path)")
    }
    defer { sqlite3_close(database) }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "SELECT data_json FROM cognitive_memory WHERE id = 1", -1, &statement, nil) == SQLITE_OK else {
      throw FaceRecognitionError.sqlite("could not read cognitive memory: \(url.path)")
    }
    defer { sqlite3_finalize(statement) }

    var object: [String: Any]
    if sqlite3_step(statement) == SQLITE_ROW {
      guard let text = sqlite3_column_text(statement, 0) else {
        throw FaceRecognitionError.invalidMemory("memory data_json is empty: \(url.path)")
      }
      let data = Data(String(cString: text).utf8)
      object = try parseMemoryObject(data, path: url.path)
    } else {
      object = [
        "schema_version": 1,
        "traces": [],
        "beliefs": [],
        "subjects": [],
        "artifacts": [],
        "dreams": [],
      ]
    }
    guard let subjects = object["subjects"] as? [[String: Any]] else {
      throw FaceRecognitionError.invalidMemory("memory subjects field must be a list: \(url.path)")
    }
    return CognitiveMemory(data: object, subjects: subjects)
  }

  mutating func subjectIndex(personID: String?, name: String?) throws -> Int {
    let active = subjects.enumerated().filter { CognitiveSubject(raw: $0.element).relationshipStatus != "forgotten" }
    if let personID {
      guard let match = active.first(where: { CognitiveSubject(raw: $0.element).personID == personID }) else {
        throw FaceRecognitionError.invalidRequest("no active person with person_id: \(personID)")
      }
      return match.offset
    }
    let wanted = name?.lowercased() ?? ""
    let matches = active.filter {
      (CognitiveSubject(raw: $0.element).displayName ?? "").lowercased() == wanted
    }
    guard let match = matches.first else {
      throw FaceRecognitionError.invalidRequest("no active person named: \(name ?? "")")
    }
    guard matches.count == 1 else {
      throw FaceRecognitionError.invalidRequest("multiple active people named \(name ?? ""); use person_id")
    }
    return match.offset
  }

  mutating func save(to url: URL) throws {
    data["subjects"] = subjects
    try Self.ensureSchema(at: url)
    var database: OpaquePointer?
    guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
      throw FaceRecognitionError.sqlite("could not open memory database for writing: \(url.path)")
    }
    defer { sqlite3_close(database) }

    let jsonData = try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])
    let json = String(decoding: jsonData, as: UTF8.self)
    var statement: OpaquePointer?
    let sql = """
      INSERT INTO cognitive_memory (id, data_json)
      VALUES (1, ?)
      ON CONFLICT(id) DO UPDATE SET data_json = excluded.data_json
      """
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
      throw FaceRecognitionError.sqlite("could not update cognitive memory: \(url.path)")
    }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    sqlite3_bind_text(statement, 1, json, -1, transient)
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw FaceRecognitionError.sqlite("could not write cognitive memory: \(url.path)")
    }
  }

  private static func ensureSchema(at url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var database: OpaquePointer?
    guard sqlite3_open(url.path, &database) == SQLITE_OK else {
      throw FaceRecognitionError.sqlite("could not open memory database: \(url.path)")
    }
    defer { sqlite3_close(database) }
    let sql = """
      PRAGMA foreign_keys = ON;
      PRAGMA user_version = 1;
      CREATE TABLE IF NOT EXISTS cognitive_memory (
        id INTEGER PRIMARY KEY CHECK(id = 1),
        data_json TEXT NOT NULL
      );
      """
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
      throw FaceRecognitionError.sqlite("could not ensure cognitive memory schema: \(url.path)")
    }
  }

  private static func parseMemoryObject(_ data: Data, path: String) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw FaceRecognitionError.invalidMemory("memory root must be an object: \(path)")
    }
    return object
  }
}

nonisolated private enum NPY {
  static func read(from url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)
    guard data.count >= 12,
          data[0] == 0x93,
          String(decoding: data[1..<6], as: UTF8.self) == "NUMPY"
    else {
      throw FaceRecognitionError.invalidEmbedding("invalid npy file: \(url.path)")
    }
    let major = data[6]
    let headerStart: Int
    let headerLength: Int
    if major == 1 {
      headerLength = Int(data[8]) | (Int(data[9]) << 8)
      headerStart = 10
    } else if major == 2 {
      headerLength = Int(data[8]) | (Int(data[9]) << 8) | (Int(data[10]) << 16) | (Int(data[11]) << 24)
      headerStart = 12
    } else {
      throw FaceRecognitionError.invalidEmbedding("unsupported npy version: \(url.path)")
    }
    let valueStart = headerStart + headerLength
    guard valueStart <= data.count, (data.count - valueStart).isMultiple(of: 4) else {
      throw FaceRecognitionError.invalidEmbedding("invalid npy float payload: \(url.path)")
    }
    return stride(from: valueStart, to: data.count, by: 4).map { offset in
      let bits = UInt32(data[offset])
        | (UInt32(data[offset + 1]) << 8)
        | (UInt32(data[offset + 2]) << 16)
        | (UInt32(data[offset + 3]) << 24)
      return Float(bitPattern: bits)
    }
  }

  static func write(_ values: [Float], to url: URL) throws {
    var header = "{'descr': '<f4', 'fortran_order': False, 'shape': (\(values.count),), }"
    let prefixLength = 10
    let padding = 16 - ((prefixLength + header.utf8.count + 1) % 16)
    header += String(repeating: " ", count: padding) + "\n"
    guard header.utf8.count <= UInt16.max else {
      throw FaceRecognitionError.invalidEmbedding("npy header is too large")
    }
    var data = Data([0x93]) + Data("NUMPY".utf8) + Data([1, 0])
    let headerLength = UInt16(header.utf8.count)
    data.append(UInt8(headerLength & 0xff))
    data.append(UInt8((headerLength >> 8) & 0xff))
    data.append(Data(header.utf8))
    for value in values {
      let bits = value.bitPattern
      data.append(UInt8(bits & 0xff))
      data.append(UInt8((bits >> 8) & 0xff))
      data.append(UInt8((bits >> 16) & 0xff))
      data.append(UInt8((bits >> 24) & 0xff))
    }
    try data.write(to: url, options: .atomic)
  }
}
