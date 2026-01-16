import Commander
import Foundation
import IMsgCore

enum HelperServerCommand {
  static let spec = CommandSpec(
    name: "helper-server",
    abstract: "Run TCP server for BlueBubbles helper connection",
    discussion: """
      Starts a TCP server that the BlueBubbles helper bundle connects to.
      The helper is injected into Messages.app by MacForge and connects
      to this server to receive commands for typing indicators, reactions, etc.
      
      Port is calculated as 45670 + (uid - 501). For uid 501, port is 45670.
      """,
    signature: CommandSignatures.withRuntimeFlags(
      CommandSignature(
        options: CommandSignatures.baseOptions() + [
          .make(label: "port", names: [.long("port"), .short("p")], help: "port to listen on (default: auto-calculated from uid)"),
        ]
      )
    ),
    usageExamples: [
      "imsg helper-server",
      "imsg helper-server --port 45670",
    ]
  ) { values, runtime in
    try await run(values: values, runtime: runtime)
  }
  
  static func run(values: ParsedValues, runtime: RuntimeOptions) async throws {
    let defaultPort = 45670 + Int(getuid()) - 501
    let port = values.optionInt("port") ?? defaultPort
    
    let server = HelperServer(port: port, verbose: runtime.verbose, jsonOutput: runtime.jsonOutput)
    try await server.run()
  }
}

// MARK: - Helper Server

actor HelperServer {
  private let port: Int
  private let verbose: Bool
  private let jsonOutput: Bool
  private var listener: Task<Void, Error>?
  private var clients: [ObjectIdentifier: HelperClient] = [:]
  
  init(port: Int, verbose: Bool, jsonOutput: Bool) {
    self.port = port
    self.verbose = verbose
    self.jsonOutput = jsonOutput
  }
  
  func run() async throws {
    log("Starting helper server on port \(port)...")
    
    // Create socket
    let serverFd = socket(AF_INET, SOCK_STREAM, 0)
    guard serverFd >= 0 else {
      throw HelperServerError.socketCreationFailed(errno)
    }
    defer { close(serverFd) }
    
    // Set SO_REUSEADDR
    var reuseAddr: Int32 = 1
    setsockopt(serverFd, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))
    
    // Bind
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(port).bigEndian
    addr.sin_addr.s_addr = INADDR_ANY.bigEndian
    
    let bindResult = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
        bind(serverFd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bindResult == 0 else {
      throw HelperServerError.bindFailed(errno, port)
    }
    
    // Listen
    guard listen(serverFd, 5) == 0 else {
      throw HelperServerError.listenFailed(errno)
    }
    
    log("Listening on port \(port)")
    log("Waiting for BlueBubbles helper to connect...")
    log("Commands (type JSON on stdin): start-typing, stop-typing, send-reaction, mark-chat-read")
    
    // Start stdin reader for commands
    let stdinTask = Task {
      await self.readStdinCommands()
    }
    
    // Accept connections
    while !Task.isCancelled {
      var clientAddr = sockaddr_in()
      var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
      
      let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
          accept(serverFd, sockaddrPtr, &clientAddrLen)
        }
      }
      
      guard clientFd >= 0 else {
        if errno == EINTR { continue }
        throw HelperServerError.acceptFailed(errno)
      }
      
      log("Client connected (fd: \(clientFd))")
      
      let client = HelperClient(fd: clientFd, verbose: verbose, jsonOutput: jsonOutput)
      let id = ObjectIdentifier(client)
      clients[id] = client
      
      Task {
        await client.run()
        await self.removeClient(id)
      }
    }
    
    stdinTask.cancel()
  }
  
  private func readStdinCommands() async {
    while !Task.isCancelled {
      guard let line = readLine() else { break }
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }
      
      // Parse as JSON command
      guard let data = trimmed.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        log("Invalid JSON command: \(trimmed)")
        continue
      }
      
      // Broadcast to all connected helpers
      await broadcastCommand(json)
    }
  }
  
  func broadcastCommand(_ command: [String: Any]) async {
    for client in clients.values {
      await client.sendCommand(command)
    }
  }
  
  private func removeClient(_ id: ObjectIdentifier) {
    clients.removeValue(forKey: id)
    log("Client disconnected")
  }
  
  private func log(_ message: String) {
    if jsonOutput {
      let json: [String: Any] = ["type": "log", "message": message]
      if let data = try? JSONSerialization.data(withJSONObject: json),
         let str = String(data: data, encoding: .utf8) {
        print(str)
      }
    } else {
      print("[helper-server] \(message)")
    }
  }
}

// MARK: - Helper Client

actor HelperClient {
  private let fd: Int32
  private let verbose: Bool
  private let jsonOutput: Bool
  private var buffer = Data()
  
  init(fd: Int32, verbose: Bool, jsonOutput: Bool) {
    self.fd = fd
    self.verbose = verbose
    self.jsonOutput = jsonOutput
  }
  
  func run() async {
    defer { close(fd) }
    
    var readBuffer = [UInt8](repeating: 0, count: 4096)
    
    while !Task.isCancelled {
      let bytesRead = read(fd, &readBuffer, readBuffer.count)
      if bytesRead <= 0 {
        break
      }
      
      buffer.append(contentsOf: readBuffer[0..<bytesRead])
      await processBuffer()
    }
  }
  
  private func processBuffer() async {
    while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
      let lineData = buffer[..<newlineIndex]
      buffer = buffer[(newlineIndex + 1)...]
      
      if let line = String(data: lineData, encoding: .utf8) {
        await handleMessage(line)
      }
    }
  }
  
  private func handleMessage(_ message: String) async {
    let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    
    log("Received from helper: \(trimmed)")
    
    // Parse JSON message from helper
    guard let data = trimmed.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      log("Invalid JSON from helper")
      return
    }
    
    // The helper sends events like typing status updates
    if let event = json["event"] as? String {
      switch event {
      case "typing-indicator":
        // Someone is typing in a chat
        if let chatGuid = json["chatGuid"] as? String,
           let isTyping = json["isTyping"] as? Bool {
          log("Typing indicator: \(chatGuid) isTyping=\(isTyping)")
          outputEvent(["type": "typing-indicator", "chatGuid": chatGuid, "isTyping": isTyping])
        }
      case "message-read":
        if let chatGuid = json["chatGuid"] as? String {
          log("Message read: \(chatGuid)")
          outputEvent(["type": "message-read", "chatGuid": chatGuid])
        }
      case "connected":
        log("Helper connected and ready")
        outputEvent(["type": "helper-connected"])
      default:
        log("Unknown event from helper: \(event)")
      }
    }
  }
  
  // Send command TO the helper
  func sendCommand(_ command: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: command),
          var str = String(data: data, encoding: .utf8) else {
      return
    }
    str += "\n"
    _ = str.withCString { ptr in
      write(fd, ptr, strlen(ptr))
    }
    log("Sent to helper: \(str.trimmingCharacters(in: .newlines))")
  }
  
  private func outputEvent(_ event: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: event),
       let str = String(data: data, encoding: .utf8) {
      print(str)
      fflush(stdout)
    }
  }
  
  private func log(_ message: String) {
    if verbose {
      if jsonOutput {
        let json: [String: Any] = ["type": "debug", "message": message]
        if let data = try? JSONSerialization.data(withJSONObject: json),
           let str = String(data: data, encoding: .utf8) {
          print(str)
        }
      } else {
        print("[helper-client] \(message)")
      }
    }
  }
}

// MARK: - Errors

enum HelperServerError: LocalizedError {
  case socketCreationFailed(Int32)
  case bindFailed(Int32, Int)
  case listenFailed(Int32)
  case acceptFailed(Int32)
  
  var errorDescription: String? {
    switch self {
    case .socketCreationFailed(let err):
      return "Failed to create socket: \(String(cString: strerror(err)))"
    case .bindFailed(let err, let port):
      return "Failed to bind to port \(port): \(String(cString: strerror(err)))"
    case .listenFailed(let err):
      return "Failed to listen: \(String(cString: strerror(err)))"
    case .acceptFailed(let err):
      return "Failed to accept connection: \(String(cString: strerror(err)))"
    }
  }
}
