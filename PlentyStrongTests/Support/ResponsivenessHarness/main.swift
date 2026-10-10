import Darwin
import Foundation
import TrainingCore

func physicalMain() -> Bool { Thread.isMainThread }

final class Diag: @unchecked Sendable {
  static let shared = Diag()
  struct Stat: Codable {
    var count = 0
    var main = 0
    var seconds = 0.0
  }
  private let lock = NSLock()
  private var stats: [String: Stat] = [:]
  private var last = ProcessInfo.processInfo.systemUptime
  private var maxGap = 0.0
  func enter(_ name: String) -> Double {
    lock.lock()
    var s = stats[name, default: Stat()]
    s.count += 1
    s.main += physicalMain() ? 1 : 0
    stats[name] = s
    lock.unlock()
    return ProcessInfo.processInfo.systemUptime
  }
  func leave(_ name: String, _ start: Double) {
    lock.lock()
    stats[name, default: Stat()].seconds += ProcessInfo.processInfo.systemUptime - start
    lock.unlock()
  }
  func beat() {
    lock.lock()
    let n = ProcessInfo.processInfo.systemUptime
    maxGap = max(maxGap, n - last)
    last = n
    lock.unlock()
  }
  func reset() {
    lock.lock()
    stats = [:]
    last = ProcessInfo.processInfo.systemUptime
    maxGap = 0
    lock.unlock()
  }
  func output(_ operation: String, _ elapsed: Double, _ cpu: Double) {
    lock.lock()
    let s = stats
    let gap = max(maxGap, ProcessInfo.processInfo.systemUptime - last)
    lock.unlock()
    let data = try! JSONEncoder().encode(s)
    print(
      "RESULT operation=\(operation) wall=\(elapsed) cpu=\(cpu) maxMainHeartbeatGap=\(gap) stats=\(String(decoding:data,as:UTF8.self))"
    )
    fflush(stdout)
  }
}
@MainActor func measure<T>(_ name: String, _ body: () async throws -> T) async throws -> T {
  Diag.shared.reset()
  let start = ProcessInfo.processInfo.systemUptime
  let cpu = clock()
  let value = try await body()
  Diag.shared.output(
    name, ProcessInfo.processInfo.systemUptime - start,
    Double(clock() - cpu) / Double(CLOCKS_PER_SEC))
  return value
}
@MainActor func run() async throws {
  let mode = CommandLine.arguments[1]
  let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
  let source = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  print("START mode=\(mode) mainActorPhysicalMain=\(physicalMain())")
  fflush(stdout)
  let url = root.appendingPathComponent("training.store")
  let repository: TrainingRepository
  if mode == "main" {
    repository = try TrainingRepository.open(at: url, archiveDirectory: source)
    print("CREATOR physicalMain=\(physicalMain())")
  } else {
    repository = try await TrainingRepository.openInBackground(at: url, archiveDirectory: source)
  }
  let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
  let initial = try await measure("ConfirmProgram.freshStore") {
    return try await Task.detached(priority: .userInitiated) {
      var config = try selectStarterProgram(choice: .upperBody, goal: .size, programID: id)
      for movement in config.movements where movement.loadingMode == .externalLoad {
        config.initialLoads[movement.id] = .some(movement.availableLoads.first)
      }
      // Fresh-store path of requireSafeNewProgram, with all admission checks retained.
      let document = try await repository.exportBackup()
      guard document.drafts.isEmpty else { fatalError() }
      let proof = try RecoveryVerifier().verify(BackupService.recoveryRecords(document))
      try validate(config: config, rules: RulesetCatalog.starter(.upperBody))
      guard proof.waiting.isEmpty, proof.quarantined.isEmpty else { fatalError() }
      for choice in StarterProgramChoice.allCases {
        _ = try StarterProgramCatalog.definition(choice)
      }
      return try await repository.initialize(
        config: config, rules: RulesetCatalog.starter(.upperBody),
        firstWorkout: WorkoutSlot(date: try LocalDate(iso8601: "2026-10-11"), slotID: "SUN"))
    }.value
  }
  let model = WorkoutViewModel(
    repository: repository, snapshot: initial, timeZoneID: "Pacific/Honolulu",
    now: { Date(timeIntervalSince1970: 1_791_583_200) })
  try await measure("StartRoutine.firstStart") { try await model.start(easierToday: false) }
  let row = model.snapshot.draft!.displayed.exercises.first { $0.load != nil }!
  try await measure("ConfirmPrescribedLoad.twoJournalEntries") {
    try await model.confirmLoad(movementID: row.movementID, load: row.load!)
  }
  try await measure("StartRoutine.existingDraft") { try await model.start(easierToday: false) }
  _ = try await measure("Snapshot.detachedCaller") {
    try await Task.detached { try await repository.snapshot(programID: id) }.value
  }
  print("END counts=\(try await repository.counts())")
  await repository.close()
}
let timer = Timer.scheduledTimer(withTimeInterval: 0.01, repeats: true) { _ in Diag.shared.beat() }
Task { @MainActor in
  do {
    try await run()
    exit(0)
  } catch {
    print("ERROR \(error)")
    fflush(stdout)
    exit(1)
  }
}
RunLoop.main.run()
