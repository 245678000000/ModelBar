import Foundation
import ModelBarCore

let arguments = CommandLine.arguments
guard let flag = arguments.firstIndex(of: "--config"), flag + 1 < arguments.count else {
    fputs("用法：ModelBarGateway --config <配置文件>\n", stderr)
    exit(2)
}
let configFile = URL(fileURLWithPath: arguments[flag + 1])

do {
    let config = try BridgeConfig.load(from: configFile)
    let server = try BridgeServer(configFile: configFile, port: config.port)
    server.start()
    dispatchMain()
} catch {
    fputs("无法启动：\(error.localizedDescription)\n", stderr)
    exit(1)
}
