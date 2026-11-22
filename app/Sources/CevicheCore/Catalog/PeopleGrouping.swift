import Accelerate
import Foundation

/// Puts faces into people by their embeddings (`FaceEmbedding`). People already made keep every face they have: only
/// faces nobody holds are placed, in capture order, each with the person whose average embedding is most like it, when
/// that is clear: a cosine similarity of `threshold` or more, ahead of the next person by `margin`, and the person has no
/// other face in the same photo. A face that fits nobody starts a group of its own, and a group that gathers
/// `minimumGroup` faces becomes a new person; single faces wait for the next run.
///
/// Measured on 2,893 faces of a real catalog: 0.03 s; of 162 labelled same-person pairs 130 ended up together, and none
/// of 82 different-person pairs did. The same-photo rule matters: 18 of 2,206 pairs of different faces in one photo
/// (people at a table, faces in artwork) scored above the threshold.
public enum PeopleGrouping {
    public static let threshold: Float = 0.50
    public static let margin: Float = 0.05
    public static let minimumGroup = 2

    public struct Face: Sendable {
        public var key: CatalogFaceKey
        /// Unit length, `FaceEmbedding.count` values.
        public var vector: [Float]
        /// As the catalog keeps it: text that sorts in time order.
        public var captureTime: String?
        public var personID: String?
        /// Placed or taken out by hand: never moved by grouping. A pinned face with no person stays out of every group.
        public var pinned: Bool
        public init(key: CatalogFaceKey, vector: [Float], captureTime: String?, personID: String?, pinned: Bool) {
            self.key = key; self.vector = vector; self.captureTime = captureTime; self.personID = personID; self.pinned = pinned
        }
    }
    public struct Result: Equatable, Sendable {
        /// Faces given to a person that already existed.
        public var joined: [CatalogFaceKey: String] = [:]
        /// New people, each with its faces in capture order.
        public var created: [[CatalogFaceKey]] = []
    }

    public static func group(_ faces: [Face]) -> Result {
        let dimension = FaceEmbedding.count
        var sums: [[Float]] = []
        var means: [Float] = []
        var photos: [Set<String>] = []
        var owner: [String?] = []
        var members: [[CatalogFaceKey]] = []
        var index: [String: Int] = [:]
        func add(_ face: Face, to group: Int) {
            let sum = vDSP.add(sums[group], face.vector)
            sums[group] = sum
            let length = sqrt(vDSP.sumOfSquares(sum))
            for i in 0..<dimension { means[group * dimension + i] = length > 0 ? sum[i] / length : 0 }
            photos[group].insert(face.key.assetID)
            members[group].append(face.key)
        }
        func newGroup(person: String?) -> Int {
            sums.append([Float](repeating: 0, count: dimension)); means.append(contentsOf: [Float](repeating: 0, count: dimension))
            photos.append([]); owner.append(person); members.append([])
            return sums.count - 1
        }
        for face in faces where face.vector.count == dimension {
            guard let person = face.personID else { continue }
            let group = index[person] ?? newGroup(person: person)
            index[person] = group
            add(face, to: group)
        }
        let waiting = faces.filter { $0.personID == nil && !$0.pinned && $0.vector.count == dimension }.sorted {
            switch ($0.captureTime, $1.captureTime) {
            case let (a?, b?) where a != b: return a < b
            case (.some, nil): return true
            case (nil, .some): return false
            default: return ($0.key.assetID, $0.key.index) < ($1.key.assetID, $1.key.index)
            }
        }
        var scores: [Float] = []
        for face in waiting {
            let count = sums.count
            var chosen: Int?
            if count > 0 {
                scores = [Float](repeating: 0, count: count)
                means.withUnsafeBufferPointer { m in
                    face.vector.withUnsafeBufferPointer { v in
                        scores.withUnsafeMutableBufferPointer { s in
                            cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(count), Int32(dimension), 1, m.baseAddress, Int32(dimension), v.baseAddress, 1, 0, s.baseAddress, 1)
                        }
                    }
                }
                for group in 0..<count where scores[group] >= threshold && photos[group].contains(face.key.assetID) { scores[group] = -1 }
                var best = 0, runner: Float = -1
                for group in 1..<max(1, count) where scores[group] > scores[best] { best = group }
                for group in 0..<count where group != best { runner = max(runner, scores[group]) }
                if scores[best] >= threshold, scores[best] - runner >= margin { chosen = best }
            }
            add(face, to: chosen ?? newGroup(person: nil))
        }
        let placed = Set(waiting.map(\.key))
        var result = Result()
        for group in members.indices {
            if let person = owner[group] {
                for key in members[group] where placed.contains(key) { result.joined[key] = person }
            } else if members[group].count >= minimumGroup {
                result.created.append(members[group])
            }
        }
        return result
    }
}

/// A face by its photo and its place in that photo, as `assetFace` keys it.
public struct CatalogFaceKey: Hashable, Comparable, Sendable, Codable {
    public var assetID: String
    public var index: Int
    public init(assetID: String, index: Int) { self.assetID = assetID; self.index = index }
    public static func < (a: Self, b: Self) -> Bool { (a.assetID, a.index) < (b.assetID, b.index) }
}
