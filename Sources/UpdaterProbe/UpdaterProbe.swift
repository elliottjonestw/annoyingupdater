import Foundation
import UpdaterCore

@main
enum UpdaterProbe {
    static func main() async throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if CommandLine.arguments.contains("--inventory") {
            let items = Inventory.discover().map(\.item)
            FileHandle.standardOutput.write(try encoder.encode(items))
        } else if let index = CommandLine.arguments.firstIndex(of: "--provider"), CommandLine.arguments.indices.contains(index + 1) {
            let apps = Inventory.discover().filter { !$0.isAppStore }
            let name = CommandLine.arguments[index + 1]
            let result: ([UpdateItem], ProviderReport)
            switch name {
            case "tools":
                let tools = await CommandLineTools.check()
                FileHandle.standardOutput.write(try encoder.encode(ScanResult(items: tools.items, reports: tools.reports,
                    observation: HistoryObservation(software: tools.snapshots, uncertainPaths: tools.uncertainPaths))))
                return
            case "homebrew-catalog": result = await HomebrewCatalogProvider.check(apps)
            case "app-catalog": result = await AppCatalogProvider.check(apps)
            case "electron": result = await ElectronProvider.check(apps)
            case "github": result = await GitHubProvider.check(apps)
            default: throw CheckError.failed("Unknown provider: \(name)")
            }
            FileHandle.standardOutput.write(try encoder.encode(ScanResult(items: result.0, reports: [result.1])))
        } else {
            let country = Locale.current.region?.identifier ?? "US"
            let result = await ScanService.scan(country: country)
            FileHandle.standardOutput.write(try encoder.encode(result))
        }
    }
}
