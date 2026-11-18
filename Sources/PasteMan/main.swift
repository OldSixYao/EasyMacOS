import AppKit

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == ScreenshotRecognitionProcess.argument {
    ScreenshotRecognitionProcess.runWorker(requestURL: URL(fileURLWithPath: CommandLine.arguments[2]))
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
