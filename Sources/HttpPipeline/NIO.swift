import Foundation
import NIO
import NIOHTTP1
import Optics
import Prelude

public func run(
  _ middleware: @escaping Middleware<StatusLineOpen, ResponseEnded, Prelude.Unit, Data>,
  on port: Int = 8080,
  gzip: Bool = false,
  baseUrl: URL
  ) {

  do {
    let reuseAddrOpt = ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR)
    let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    let bootstrap = ServerBootstrap(group: group)
      .serverChannelOption(ChannelOptions.backlog, value: 256)
      .serverChannelOption(reuseAddrOpt, value: 1)
      .childChannelInitializer { channel in
        channel.pipeline.configureHTTPServerPipeline().then {
          let handlers: [ChannelHandler] = gzip
            ? [HTTPResponseCompressor(), Handler(baseUrl: baseUrl, middleware: middleware)]
            : [Handler(baseUrl: baseUrl, middleware: middleware)]
          return channel.pipeline.addHandlers(handlers, first: false)
        }
      }
      .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
      .childChannelOption(reuseAddrOpt, value: 1)
      .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)

    let host = "0.0.0.0"
    let serverChannel = try bootstrap.bind(host: host, port: port).wait()
    print("Listening on \(host):\(port)...")
    try serverChannel.closeFuture.wait()
    try group.syncShutdownGracefully()
  } catch {
    fatalError(error.localizedDescription)
  }
}

private final class Handler: ChannelInboundHandler {
  typealias InboundIn = HTTPServerRequestPart

  let baseUrl: URL
  var request: URLRequest?
  let middleware: Middleware<StatusLineOpen, ResponseEnded, Prelude.Unit, Data>

  init(baseUrl: URL, middleware: @escaping Middleware<StatusLineOpen, ResponseEnded, Prelude.Unit, Data>) {
    self.baseUrl = baseUrl
    self.middleware = middleware
  }

  func channelRead(ctx: ChannelHandlerContext, data: NIOAny) {
    let reqPart = self.unwrapInboundIn(data)

    switch reqPart {
    case let .head(header):
      self.request = URL(string: header.uri).map {
        var req = URLRequest(url: $0)
        req.httpMethod = method(from: header.method)
        req.allHTTPHeaderFields = header.headers.reduce(into: [:]) { $0[$1.name] = $1.value }
        let proto = req.value(forHTTPHeaderField: "X-Forwarded-Proto") ?? "http"
        req.url = req.value(forHTTPHeaderField: "Host").flatMap {
          URL(string: proto + "://" + $0 + header.uri)
        }
        return req
      }
    case var .body(bodyPart):
      self.request = self.request |> map <<< \.httpBody %~ {
        var data = $0 ?? .init()
        bodyPart.readBytes(length: bodyPart.readableBytes).do { data.append(Data($0)) }
        return data
      }
    case .end:
      guard let req = self.request else {
        ctx.channel.write(
          HTTPServerResponsePart.head(
            HTTPResponseHead(
              version: .init(major: 1, minor: 1),
              status: .init(statusCode: 307),
              headers: .init([("location", self.baseUrl.absoluteString)])
            )
          ),
          promise: nil
        )
        _ = ctx.channel.writeAndFlush(HTTPServerResponsePart.end(nil)).then {
          ctx.channel.close()
        }
        return
      }

      let promise = ctx.eventLoop.newPromise(of: Conn<ResponseEnded, Data>.self)
      self.middleware(connection(from: req)).parallel.run(promise.succeed(result:))
      _ = promise.futureResult.then { conn -> EventLoopFuture<Void> in
        let res = conn.response

        let head = HTTPResponseHead(
          version: .init(major: 1, minor: 1),
          status: .init(statusCode: res.status.rawValue),
          headers: .init(res.headers.map { ($0.name, $0.value) })
        )
        ctx.channel.write(HTTPServerResponsePart.head(head), promise: nil)

        var buffer = ctx.channel.allocator.buffer(capacity: res.body.count)
        buffer.write(bytes: res.body)
        ctx.channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)

        return ctx.channel.writeAndFlush(HTTPServerResponsePart.end(nil)).then {
          ctx.channel.close()
        }
      }
    }
  }

  func errorCaught(ctx: ChannelHandlerContext, error: Error) {
    ctx.close(promise: nil)
  }
}

private func method(from method: HTTPMethod) -> String {
  switch method {
  case .GET: return "GET"
  case .PUT: return "PUT"
  case .ACL: return "ACL"
  case .HEAD: return "HEAD"
  case .POST: return "POST"
  case .COPY: return "COPY"
  case .LOCK: return "LOCK"
  case .MOVE: return "MOVE"
  case .BIND: return "BIND"
  case .LINK: return "LINK"
  case .PATCH: return "PATCH"
  case .TRACE: return "TRACE"
  case .MKCOL: return "MKCOL"
  case .MERGE: return "MERGE"
  case .PURGE: return "PURGE"
  case .NOTIFY: return "NOTIFY"
  case .SEARCH: return "SEARCH"
  case .UNLOCK: return "UNLOCK"
  case .REBIND: return "REBIND"
  case .UNBIND: return "UNBIND"
  case .REPORT: return "REPORT"
  case .DELETE: return "DELETE"
  case .UNLINK: return "UNLINK"
  case .CONNECT: return "CONNECT"
  case .MSEARCH: return "MSEARCH"
  case .OPTIONS: return "OPTIONS"
  case .PROPFIND: return "PROPFIND"
  case .CHECKOUT: return "CHECKOUT"
  case .PROPPATCH: return "PROPPATCH"
  case .SUBSCRIBE: return "SUBSCRIBE"
  case .MKCALENDAR: return "MKCALENDAR"
  case .MKACTIVITY: return "MKACTIVITY"
  case .UNSUBSCRIBE: return "UNSUBSCRIBE"
  case let .RAW(value): return value
  }
}
