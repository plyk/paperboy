import Foundation

/// Külső parancs (ssh, ssh-keygen) futtatása aszinkron módon, a kimenet begyűjtésével.
enum ProcessRunner {
    struct Output {
        let status: Int32
        let stdout: Data
        let stderr: String

        var succeeded: Bool { status == 0 }
        var text: String { String(decoding: stdout, as: UTF8.self) }
    }

    static func run(_ executable: String, _ arguments: [String], input: Data? = nil,
                    environment: [String: String] = [:], timeout: TimeInterval = 60) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
            let stdout = Pipe()
            let stderr = Pipe()
            let stdin = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = stdin

            let group = DispatchGroup()
            // A DispatchGroup gondoskodik róla, hogy az olvasás az eredmény összeállítása előtt befejeződjön.
            let outData = Buffer()
            let errData = Buffer()
            // Indítás előtt jelezzük az olvasásokat, különben egy gyorsan kilépő folyamatnál az eredmény
            // a kimenet beolvasása előtt állna össze.
            group.enter()
            group.enter()
            process.terminationHandler = { process in
                group.notify(queue: .global()) {
                    continuation.resume(returning: Output(status: process.terminationStatus, stdout: outData.data,
                                                          stderr: String(decoding: errData.data, as: UTF8.self)))
                }
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }

            // A kimeneteket külön szálon olvassuk, különben a megtelt pipe megakaszthatja a folyamatot.
            DispatchQueue.global().async {
                outData.data = stdout.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            DispatchQueue.global().async {
                errData.data = stderr.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            DispatchQueue.global().async {
                if let input { try? stdin.fileHandleForWriting.write(contentsOf: input) }
                try? stdin.fileHandleForWriting.close()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if process.isRunning { process.terminate() }
            }
        }
    }
}

private final class Buffer: @unchecked Sendable {
    var data = Data()
}
