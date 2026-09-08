import Foundation
import DivoomProtocol

do { try CLI.run(Array(CommandLine.arguments.dropFirst())) }
catch let error as UsageError { log("Error: \(error.message)"); exit(2) }
catch { log("Error: \(error.localizedDescription)"); exit(1) }
