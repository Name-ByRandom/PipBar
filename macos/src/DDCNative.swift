import AppKit
import IOKit

// MARK: - 原生 DDC/CI 实现
//
// 协议依据 Crisp (didriksg/Crisp) 的正确实现：
//   读 GetVCP  : [0x82, 0x01, code] + checksum(0x6E^0x51^payload)
//   写 SetVCP  : [0x84, 0x03, code, hi, lo] + checksum
//   读响应     : [0x6E, 0x88, 0x02, 0x00, code, type, maxHi, maxLo, curHi, curLo, chk]
//
// 关键校验（m1ddc 缺失的部分，导致它读出 110）：
//   1. 响应必须是 0x6E 开头、opcode 0x02、result 0x00
//   2. 响应第 5 字节必须回显我们请求的 VCP 码
//   3. 校验和必须匹配（0x50 种子异或前 10 字节）
//   4. max 不能为 0
// 少任何一条都会读到 EDID 残片或空帧。

typealias IOAVServiceRef = UnsafeMutableRawPointer

@_silgen_name("IOAVServiceCreateWithService")
func IOAVServiceCreateWithService(_ allocator: CFAllocator?, _ service: io_service_t) -> IOAVServiceRef?

@_silgen_name("IOAVServiceReadI2C")
func IOAVServiceReadI2C(_ service: IOAVServiceRef, _ chip: UInt32, _ offset: UInt32,
                        _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn

@_silgen_name("IOAVServiceWriteI2C")
func IOAVServiceWriteI2C(_ service: IOAVServiceRef, _ chip: UInt32, _ dataAddress: UInt32,
                         _ buffer: UnsafeMutableRawPointer, _ size: UInt32) -> IOReturn

/// 一台显示器的 DDC 通道
final class DisplayChannel {
    let avService: IOAVServiceRef
    let name: String
    let vendorID: UInt32
    let productID: UInt32

    init(avService: IOAVServiceRef, name: String, vendor: UInt32, product: UInt32) {
        self.avService = avService
        self.name = name
        self.vendorID = vendor
        self.productID = product
    }

    // MARK: 读

    /// 读取 VCP 特征。返回 (当前值, 最大值)，失败返回 nil。
    func read(_ code: UInt8) -> (current: UInt16, max: UInt16)? {
        var checksum = UInt8(0x6E ^ 0x51)
        let payload: [UInt8] = [0x82, 0x01, code]
        for b in payload { checksum ^= b }
        var request = payload + [checksum]

        let w = request.withUnsafeMutableBytes {
            IOAVServiceWriteI2C(avService, 0x37, 0x51, $0.baseAddress!, UInt32($0.count))
        }
        guard w == kIOReturnSuccess else { return nil }

        // DDC/CI 规范要求显示器约 40ms 准备响应
        Thread.sleep(forTimeInterval: 0.04)

        var reply = [UInt8](repeating: 0, count: 12)
        let r = reply.withUnsafeMutableBytes {
            IOAVServiceReadI2C(avService, 0x37, 0x51, $0.baseAddress!, UInt32($0.count))
        }
        guard r == kIOReturnSuccess, reply.count >= 11 else { return nil }

        // 校验：必须是合法的 GetVCP Feature Reply
        guard reply[0] == 0x6E,      // 源地址
              reply[2] == 0x02,      // Get VCP Feature Reply
              reply[3] == 0x00,      // 无错误
              reply[4] == code       // 回显请求的 VCP 码
        else { return nil }

        // 校验和
        var expected = UInt8(0x50)
        for i in 0...9 { expected ^= reply[i] }
        guard expected == reply[10] else { return nil }

        let maxVal = (UInt16(reply[6]) << 8) | UInt16(reply[7])
        let curVal = (UInt16(reply[8]) << 8) | UInt16(reply[9])
        guard maxVal > 0 else { return nil }
        return (curVal, maxVal)
    }

    // MARK: 写

    /// 写入 VCP 特征。
    func write(_ code: UInt8, _ value: UInt16) -> Bool {
        let hi = UInt8((value >> 8) & 0xFF)
        let lo = UInt8(value & 0xFF)
        var checksum = UInt8(0x6E ^ 0x51)
        let payload: [UInt8] = [0x84, 0x03, code, hi, lo]
        for b in payload { checksum ^= b }
        var msg = payload + [checksum]

        let r = msg.withUnsafeMutableBytes {
            IOAVServiceWriteI2C(avService, 0x37, 0x51, $0.baseAddress!, UInt32($0.count))
        }
        Thread.sleep(forTimeInterval: 0.02)
        return r == kIOReturnSuccess
    }

    /// 写入后再读回验证。
    ///
    /// Dell 显示器的两个坑（Crisp docs/ddc-notes.md 实测记录）：
    ///   1. DDC 写入会自动关闭 OSD 菜单
    ///   2. OSD 开着时 DDC 流量会把控制器写聋（no I2C ack）
    /// 所以写入必须放慢：写一次 → 等 → 读一次 → 充分休息，绝不连打。
    @discardableResult
    func writeVerified(_ code: UInt8, _ value: UInt16) -> (written: Bool, confirmed: Bool, readBack: UInt16?) {
        // 写前先探一次，确认通道还活着（被写聋时这里就会失败）
        guard read(code) != nil else {
            return (false, false, nil)   // 通道已聋
        }

        let ok = write(code, value)
        guard ok else { return (false, false, nil) }

        // 显示器切画面 + 重新建立 DDC 响应，给足时间
        var readBack: UInt16?
        var matched = false
        for _ in 0..<5 {
            Thread.sleep(forTimeInterval: 0.35)
            if let r = read(code) {
                readBack = r.current
                if r.current == value { matched = true; break }
            }
        }
        // 关键：写之间充分冷却，避免把 Dell 的 DDC 控制器写聋
        Thread.sleep(forTimeInterval: 0.6)
        return (ok, matched, readBack)
    }
}

// MARK: - 显示器发现

enum DisplayDiscovery {
    private static func u32(_ v: Any?) -> UInt32? {
        if let x = v as? UInt32 { return x }
        if let x = v as? Int { return UInt32(bitPattern: Int32(truncatingIfNeeded: x)) }
        if let n = v as? NSNumber { return n.uint32Value }
        return nil
    }

    private static func isExternal(_ attrs: [String: Any]) -> Bool {
        guard let vendor = u32(attrs["VendorID"]), vendor != 0 else { return false }
        return true
    }

    private static func className(_ entry: io_service_t) -> String? {
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: 128)
        defer { buf.deallocate() }
        guard IOObjectGetClass(entry, buf) == KERN_SUCCESS else { return nil }
        return String(cString: buf)
    }

    /// 枚举所有可用的外接显示器 DDC 通道。
    ///
    /// 关键：DDC 通道挂在 `DCPAVServiceProxy` 节点上（不是 IOFramebuffer）。
    /// 遍历时先记住最近看到的厂商 ID（DisplayAttributes 在父节点上），
    /// 再与后面的 DCPAVServiceProxy 配对。
    static func channels() -> [DisplayChannel] {
        // 第一阶段：收集 (AV节点, 当时的厂商ID, 产品名)
        var raw: [(entry: io_service_t, vendor: UInt32, name: String)] = []
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        var iterator: io_iterator_t = 0

        guard IORegistryEntryCreateIterator(
            root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator
        ) == KERN_SUCCESS else { return [] }

        var lastVendor: UInt32 = 0
        var lastName = ""
        var entry = IOIteratorNext(iterator)
        while entry != IO_OBJECT_NULL {
            // 记录最近一次出现的显示器身份（DisplayAttributes 在外接屏节点的父级）
            if let da = IORegistryEntryCreateCFProperty(
                entry, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? [String: Any] {
                if let pa = da["ProductAttributes"] as? [String: Any],
                   let v = u32(pa["LegacyManufacturerID"]) {
                    lastVendor = v
                    if let n = pa["ProductName"] as? String { lastName = n }
                }
            }

            if className(entry) == "DCPAVServiceProxy" {
                let loc = IORegistryEntryCreateCFProperty(
                    entry, "Location" as CFString, kCFAllocatorDefault, 0
                )?.takeRetainedValue() as? String
                // 只取外接屏通道（跳过内置屏的 Embedded）
                if loc?.trimmingCharacters(in: .whitespaces) == "External" {
                    raw.append((entry, lastVendor, lastName))
                } else {
                    IOObjectRelease(entry)   // 不需要，留给系统
                }
            } else {
                IOObjectRelease(entry)
            }
            entry = IOIteratorNext(iterator)
        }
        IOObjectRelease(iterator)

        // 第二阶段：建通道
        var result: [DisplayChannel] = []
        for item in raw {
            if let av = IOAVServiceCreateWithService(kCFAllocatorDefault, item.entry) {
                result.append(DisplayChannel(
                    avService: av,
                    name: item.name.isEmpty ? "外接显示器" : item.name,
                    vendor: item.vendor,
                    product: 0))
            }
            IOObjectRelease(item.entry)
        }
        return result
    }

    /// 挑出要控制的显示器通道。
    ///
    /// 优先级：厂商 ID 能匹配到已配置档 → 匹配；否则只有一块外接屏就用它。
    /// 详细的多显示器选择尚未实现（见 README 已知限制）。
    static func primaryChannel() -> DisplayChannel? {
        let all = channels()
        guard !all.isEmpty else { return nil }

        // 有配置档且厂商 ID 对得上 → 用它
        for ch in all {
            if let p = ProfileStore.profile(forEDIDName: ch.name),
               !p.vendorIdHex.isEmpty,
               UInt32(p.vendorIdHex, radix: 16) == ch.vendorID {
                return ch
            }
        }
        return all.first
    }
}

// MARK: - VCP 码

enum VCP {
    static let brightness: UInt8 = 0x10
    static let contrast: UInt8 = 0x12
    static let audioVolume: UInt8 = 0x62
    static let mute: UInt8 = 0x8D
    static let inputSource: UInt8 = 0x60
    static let pbpInput: UInt8 = 0xE8
    static let pbpMode: UInt8 = 0xE9
}
