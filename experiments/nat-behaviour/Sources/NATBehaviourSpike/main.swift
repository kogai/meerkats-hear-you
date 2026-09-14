import Foundation

// ADR-0009 が「未検証の前提」に残した NAT の実挙動を測る。
//
// **Network.framework ではなく生の UDP ソケットを使う。**
// 測りたいことの中心は「同じソケットから別の宛先へ送ったとき、外から見えるポートが
// 同じか」である。NWConnection は宛先ごとにソケットを作るので、この問いを立てられない。
// ソケットを1つに固定できることが要件なので、そこに合う道具を選んでいる。

// MARK: - STUN (RFC 5389)

let magicCookie: UInt32 = 0x2112_A442

struct Reflexive: Equatable {
    var address: String
    var port: UInt16
}

enum SpikeError: Error, CustomStringConvertible {
    case resolve(String)
    case socket(String)
    case noResponse(String)
    case malformed(String)

    var description: String {
        switch self {
        case .resolve(let s): return "名前を引けない: \(s)"
        case .socket(let s): return "ソケットが作れない: \(s)"
        case .noResponse(let s): return "応答が無い: \(s)"
        case .malformed(let s): return "応答が壊れている: \(s)"
        }
    }
}

func resolveIPv4(host: String, port: UInt16) throws -> sockaddr_in {
    var hints = addrinfo()
    hints.ai_family = AF_INET
    hints.ai_socktype = SOCK_DGRAM
    var result: UnsafeMutablePointer<addrinfo>?
    let status = getaddrinfo(host, String(port), &hints, &result)
    guard status == 0, let first = result else {
        throw SpikeError.resolve("\(host): \(String(cString: gai_strerror(status)))")
    }
    defer { freeaddrinfo(result) }
    return first.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
        $0.pointee
    }
}

func dotted(_ networkOrder: in_addr_t) -> String {
    let b = withUnsafeBytes(of: networkOrder) { Array($0) }
    return "\(b[0]).\(b[1]).\(b[2]).\(b[3])"
}

func bindingRequest(transaction: [UInt8]) -> [UInt8] {
    var packet: [UInt8] = [0x00, 0x01, 0x00, 0x00]  // Binding Request、属性なし
    packet += withUnsafeBytes(of: magicCookie.bigEndian) { Array($0) }
    packet += transaction
    return packet
}

/// 応答から反射アドレスを取り出す。
///
/// **トランザクションIDを必ず照合する。** UDP なので無関係な相手からの
/// パケットが同じソケットに届きうる。照合しないと、それを答えとして読んでしまう。
func parseResponse(_ data: [UInt8], transaction: [UInt8]) throws -> Reflexive? {
    guard data.count >= 20 else { throw SpikeError.malformed("20バイト未満") }
    let type = UInt16(data[0]) << 8 | UInt16(data[1])
    let length = Int(UInt16(data[2]) << 8 | UInt16(data[3]))
    let cookie = data[4..<8].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    guard cookie == magicCookie else { throw SpikeError.malformed("マジッククッキーが違う") }
    guard Array(data[8..<20]) == transaction else { return nil }  // 別の問い合わせへの答え
    guard type == 0x0101 else { throw SpikeError.malformed("応答種別 0x\(String(type, radix: 16))") }
    guard 20 + length <= data.count else { throw SpikeError.malformed("属性長が実体より長い") }

    var offset = 20
    while offset + 4 <= 20 + length {
        let attrType = UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
        let attrLength = Int(UInt16(data[offset + 2]) << 8 | UInt16(data[offset + 3]))
        let valueStart = offset + 4
        guard valueStart + attrLength <= data.count else { break }
        let value = Array(data[valueStart..<(valueStart + attrLength)])

        // 0x0020 = XOR-MAPPED-ADDRESS、0x0001 = MAPPED-ADDRESS
        if (attrType == 0x0020 || attrType == 0x0001) && attrLength >= 8 {
            guard value[1] == 0x01 else {
                throw SpikeError.malformed("IPv4 以外の反射アドレスが返った")
            }
            let mask: [UInt8] = attrType == 0x0020 ? [0x21, 0x12, 0xA4, 0x42] : [0, 0, 0, 0]
            let portMask: UInt16 = attrType == 0x0020 ? 0x2112 : 0
            let port = (UInt16(value[2]) << 8 | UInt16(value[3])) ^ portMask
            let octets = (0..<4).map { value[4 + $0] ^ mask[$0] }
            return Reflexive(
                address: octets.map(String.init).joined(separator: "."),
                port: port
            )
        }
        offset = valueStart + attrLength
        offset += (4 - attrLength % 4) % 4  // 属性は4バイト境界へ詰める
    }
    throw SpikeError.malformed("反射アドレスの属性が無い")
}

// MARK: - ソケット

func makeSocket() throws -> Int32 {
    let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { throw SpikeError.socket(String(cString: strerror(errno))) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_addr.s_addr = INADDR_ANY
    addr.sin_port = 0
    let bound = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bound == 0 else { throw SpikeError.socket(String(cString: strerror(errno))) }
    return fd
}

func localPort(of fd: Int32) -> UInt16 {
    var addr = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    return UInt16(bigEndian: addr.sin_port)
}

/// 経路として選ばれる自分側のアドレス。**パケットは出さない。**
/// これが反射アドレスと一致していれば、その機械は NAT の内側に居ない。
func routedLocalAddress(to server: sockaddr_in) -> String? {
    let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { return nil }
    defer { Darwin.close(fd) }
    var server = server
    let connected = withUnsafePointer(to: &server) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else { return nil }
    var local = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    guard withUnsafeMutablePointer(to: &local, { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }) == 0 else { return nil }
    return dotted(local.sin_addr.s_addr)
}

/// 1つのソケットから1つのサーバへ問い合わせる。
///
/// 3回まで送り直す。UDP なので落ちる。
func query(_ fd: Int32, _ server: sockaddr_in, _ label: String) throws -> Reflexive {
    var timeout = timeval()
    timeout.tv_sec = 1
    timeout.tv_usec = 0
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    for _ in 0..<3 {
        let transaction = (0..<12).map { _ in UInt8.random(in: 0...255) }
        let packet = bindingRequest(transaction: transaction)
        var server = server
        let sent = withUnsafePointer(to: &server) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard sent > 0 else { continue }

        let deadline = Date().addingTimeInterval(1.0)
        while Date() < deadline {
            var buffer = [UInt8](repeating: 0, count: 1500)
            let received = recvfrom(fd, &buffer, buffer.count, 0, nil, nil)
            guard received > 0 else { break }
            if let reflexive = try parseResponse(Array(buffer[0..<received]), transaction: transaction) {
                return reflexive
            }
        }
    }
    throw SpikeError.noResponse(label)
}

// MARK: - 測る

struct Server {
    var label: String
    var host: String
    var port: UInt16
}

let servers = [
    Server(label: "Google", host: "stun.l.google.com", port: 19302),
    Server(label: "Cloudflare", host: "stun.cloudflare.com", port: 3478),
]

func heading(_ text: String) {
    print("\n\(text)\n" + String(repeating: "-", count: 60))
}

do {
    var resolved: [(server: Server, addr: sockaddr_in)] = []
    for server in servers {
        resolved.append((server: server, addr: try resolveIPv4(host: server.host, port: server.port)))
    }
    let a = resolved[0], b = resolved[1]

    heading("1. STUN が通るか")
    for entry in resolved {
        print("  \(entry.server.label): \(entry.server.host) → \(dotted(entry.addr.sin_addr.s_addr))")
    }
    let distinctServers = a.addr.sin_addr.s_addr != b.addr.sin_addr.s_addr
    if !distinctServers {
        print("  ⚠ 2つのサーバが同じIPに解決された。2節の判定は成り立たない。")
    }

    let first = try makeSocket()
    let firstLocal = localPort(of: first)
    let viaA = try query(first, a.addr, a.server.label)
    print("  公開アドレス: \(viaA.address):\(viaA.port)  (自分側のポート \(firstLocal))")

    if let routed = routedLocalAddress(to: a.addr), routed == viaA.address {
        print("  ⚠ 反射アドレスが自分のアドレスと同じ。**この機械は NAT の内側に居ない。**")
        print("    測っても、普段使う回線のことは何も分からない。")
    }

    heading("2. 外から見えるポートは宛先によらないか (EIM か EDM か)")
    if distinctServers {
        let viaB = try query(first, b.addr, b.server.label)
        print("  \(a.server.label) 経由: \(viaA.address):\(viaA.port)")
        print("  \(b.server.label) 経由: \(viaB.address):\(viaB.port)")
        if viaA == viaB {
            print("  → **宛先によらない (EIM)。** 穴あけが成立する側。")
        } else {
            print("  → **宛先ごとに変わる (EDM)。** この回線では穴あけが成立しない。")
        }
    }

    heading("3. ポートの振り方")
    let second = try makeSocket()
    let secondLocal = localPort(of: second)
    let secondReflexive = try query(second, a.addr, a.server.label)
    print("  1本目: 自分側 \(firstLocal) → 外から \(viaA.port)")
    print("  2本目: 自分側 \(secondLocal) → 外から \(secondReflexive.port)")
    if firstLocal == viaA.port && secondLocal == secondReflexive.port {
        print("  → ポートをそのまま通している。")
    } else {
        let delta = Int(secondReflexive.port) - Int(viaA.port)
        print("  → 付け替えている。2本の差は \(delta)。")
    }
    Darwin.close(second)

    heading("4. 黙っていてもマッピングは何秒生きるか")
    print("  **待つ長さごとに別のソケットを使う。** 問い合わせ自体がマッピングを延命するので、")
    print("  1本を使い回すと、測れるのは最後の間隔だけになる。")
    let waits: [Int] = [30, 90, 180]
    var probes: [(wait: Int, fd: Int32, before: Reflexive)] = []
    for wait in waits {
        let fd = try makeSocket()
        probes.append((wait: wait, fd: fd, before: try query(fd, a.addr, a.server.label)))
    }
    var elapsed = 0
    for probe in probes {
        Thread.sleep(forTimeInterval: Double(probe.wait - elapsed))
        elapsed = probe.wait
        let after = try? query(probe.fd, a.addr, a.server.label)
        let alive = after == probe.before
        let shown = after.map { "\($0.address):\($0.port)" } ?? "応答なし"
        print("  \(probe.wait)秒 沈黙: \(probe.before.address):\(probe.before.port) → \(shown)  \(alive ? "生きている" : "**切れた**")")
        Darwin.close(probe.fd)
    }
    Darwin.close(first)
    print("\n完了。この出力をそのまま PR に貼ってください。")
} catch {
    print("失敗: \(error)")
    exit(1)
}
