import Foundation
import Darwin   // memset

// MARK: - SSH wire-format helpers — SINGLE source shared by both agents (#13).
// Compiled into s3c-ssh-agent (chip) AND s3c-session-agent (via ssh-agent-core). These are
// pure (no host state), so they live here once instead of being duplicated per binary.

func wireString(_ d: Data) -> Data {
    var out = Data()
    var len = UInt32(d.count).bigEndian
    out.append(Data(bytes: &len, count: 4))
    out.append(d)
    return out
}
func wireString(_ s: String) -> Data { wireString(Data(s.utf8)) }

func wireMpint(_ raw: Data) -> Data {
    var bytes = Array(raw)
    while bytes.count > 1 && bytes[0] == 0 { bytes.removeFirst() }
    if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0, at: 0) }
    return wireString(Data(bytes))
}

struct Reader {
    let data: Data
    var pos: Int = 0
    mutating func readByte() -> UInt8? {
        guard pos < data.count else { return nil }
        let b = data[pos]; pos += 1; return b
    }
    mutating func readUInt32() -> UInt32? {
        guard pos + 4 <= data.count else { return nil }
        let v = data[pos..<pos+4].withUnsafeBytes { $0.load(as: UInt32.self) }
        pos += 4; return UInt32(bigEndian: v)
    }
    mutating func readString() -> Data? {
        guard let len = readUInt32(), pos + Int(len) <= data.count else { return nil }
        let s = data.subdata(in: pos..<pos+Int(len)); pos += Int(len); return s
    }
    mutating func readMpint() -> Data? {
        guard var bytes = readString() else { return nil }
        if bytes.count > 0 && bytes[0] == 0 { bytes.removeFirst() }
        return bytes
    }
}

func zeroOut(_ d: inout Data) {
    let count = d.count
    d.withUnsafeMutableBytes { ptr in if let base = ptr.baseAddress { memset(base, 0, count) } }
    d.removeAll(keepingCapacity: false)
}

func framed(_ payload: Data) -> Data {
    var out = Data()
    var len = UInt32(payload.count).bigEndian
    out.append(Data(bytes: &len, count: 4))
    out.append(payload)
    return out
}

func parseECDSADer(_ der: Data) -> (Data, Data)? {
    var pos = 0
    guard der.count > 2, der[pos] == 0x30 else { return nil }
    pos += 1
    var seqLen = 0
    if der[pos] & 0x80 == 0 { seqLen = Int(der[pos]); pos += 1 }
    else { let n = Int(der[pos] & 0x7F); pos += 1; for _ in 0..<n { seqLen = (seqLen << 8) | Int(der[pos]); pos += 1 } }
    _ = seqLen
    func readInt() -> Data? {
        guard pos < der.count, der[pos] == 0x02 else { return nil }
        pos += 1
        var len = Int(der[pos]); pos += 1
        if len & 0x80 != 0 { let n = len & 0x7F; len = 0; for _ in 0..<n { len = (len << 8) | Int(der[pos]); pos += 1 } }
        let v = der.subdata(in: pos..<pos+len); pos += len; return v
    }
    guard let r = readInt(), let s = readInt() else { return nil }
    return (r, s)
}
