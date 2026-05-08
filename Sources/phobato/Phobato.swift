import ArgumentParser
import Foundation

struct PhobatoError: Error, CustomStringConvertible {
    let message: String
    init(_ message: String) { self.message = message }
    var description: String { message }
}

func eprint(_ s: String) {
    FileHandle.standardError.write(Data(s.utf8))
}

@main
struct Phobato: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "phobato",
        abstract: "PHOto BAckup TOol",
        subcommands: [Verify.self]
    )

    func run() throws {
        eprint(Phobato.helpMessage() + "\n")
        throw ExitCode(1)
    }
}
