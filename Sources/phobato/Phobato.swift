import ArgumentParser
import Foundation

struct PhobatoError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

func errPrint(_ s: String) {
    FileHandle.standardError.write(Data(s.utf8))
}

@main
struct Phobato: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "phobato",
        abstract: "PHOto BAckup TOol for working with backups of Apple Photos libraries in S3-compatible buckets",
        subcommands: [Go.self, Verify.self, Patch.self]
    )

    func run() throws {
        errPrint(Phobato.helpMessage() + "\n")
        throw ExitCode(1)
    }
}
