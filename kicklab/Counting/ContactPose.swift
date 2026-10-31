import Foundation

/// Stable raw keys preserve existing JSON fixtures and saved counter traces.
/// Rules use enum cases so a misspelled joint cannot silently become missing pose.
nonisolated enum BodyJoint: String, CaseIterable, Codable, CodingKey, CodingKeyRepresentable, Sendable {
    case nose
    case leftShoulder = "left_shoulder", rightShoulder = "right_shoulder"
    case leftElbow = "left_elbow", rightElbow = "right_elbow"
    case leftWrist = "left_wrist", rightWrist = "right_wrist"
    case leftHip = "left_hip", rightHip = "right_hip"
    case leftKnee = "left_knee", rightKnee = "right_knee"
    case leftAnkle = "left_ankle", rightAnkle = "right_ankle"

    var codingKey: any CodingKey { self }
    init?<T: CodingKey>(codingKey: T) { self.init(rawValue: codingKey.stringValue) }
}

nonisolated enum BodySide: String, CaseIterable, Codable, CodingKey, CodingKeyRepresentable, Sendable {
    case left, right
    var hip: BodyJoint { self == .left ? .leftHip : .rightHip }
    var knee: BodyJoint { self == .left ? .leftKnee : .rightKnee }
    var ankle: BodyJoint { self == .left ? .leftAnkle : .rightAnkle }
    var shoulder: BodyJoint { self == .left ? .leftShoulder : .rightShoulder }
    var elbow: BodyJoint { self == .left ? .leftElbow : .rightElbow }
    var wrist: BodyJoint { self == .left ? .leftWrist : .rightWrist }
    var opposite: Self { self == .left ? .right : .left }
    var codingKey: any CodingKey { self }
    init?<T: CodingKey>(codingKey: T) { self.init(rawValue: codingKey.stringValue) }
}

/// Upright normalized image coordinates, with y increasing downwards.
nonisolated struct PosePoint: Codable, Equatable, Sendable {
    var x, y: Double
}

nonisolated struct PoseLandmark: Codable, Equatable, Sendable {
    let x, y: Double
    var confidence: Double = 1
}

nonisolated struct HandLandmark: Sendable {
    /// Zero is the wrist; 1...5 identify the five fingers.
    var finger: Int
    var x, y, confidence: Double
}

nonisolated struct BodyPose: Sendable {
    var joints: [BodyJoint: PosePoint] = [:]
    var ankles: [BodySide: PoseLandmark] = [:]
    var hips: [BodySide: PoseLandmark] = [:]
    var wrists: [BodySide: PoseLandmark] = [:]
    var landmarks: [BodyJoint: PoseLandmark] = [:]
}

nonisolated struct ContactPoseSample: Codable, Equatable, Sendable {
    let timestampMs: Int
    let ball: PosePoint
    let width, height, confidence, imageAspect: Double
    let joints: [BodyJoint: PosePoint]
}

nonisolated struct FootPoseSample: Codable, Equatable, Sendable {
    let pose: ContactPoseSample
    /// Keep observed confidence, including weak ankles used only with corroboration.
    let ankles: [BodySide: PoseLandmark]
    var landmarks: [BodyJoint: PoseLandmark] = [:]
    var corroboratedAnkles: Set<BodySide> = []
}
