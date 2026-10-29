import Foundation
import IOKit
import IOKit.hid

enum HIDBridgeError: Error, CustomStringConvertible {
    case openFailed(Int32)
    case setReportFailed(Int32, length: Int)

    var description: String {
        switch self {
        case .openFailed(let e): return "IOHIDDeviceOpen falhou (ior=0x\(String(UInt32(bitPattern: e), radix: 16)))"
        case .setReportFailed(let e, let l): return "SetReport falhou (ior=0x\(String(UInt32(bitPattern: e), radix: 16)), len=\(l))"
        }
    }
}

/// Envoltório de um IOHIDDevice, aberto em modo compartilhado quando o driver precisa falar com ele.
final class HIDDeviceBridge: @unchecked Sendable {
    let device: IOHIDDevice
    /// Runloop que carrega os callbacks de input (thread HID dedicada).
    private let runLoop: CFRunLoop
    private var opened = false
    private var inputBuffer: UnsafeMutablePointer<UInt8>?

    private let inLock = NSLock()
    private var inputBodies: [[UInt8]] = []
    /// Um pedido HID++ por vez. Cada pedido esvazia a fila de input, então dois ao mesmo tempo descartam a resposta um do outro.
    let requestLock = NSLock()

    // Trace de diagnóstico (CLI "probe" imprime no fim).
    private let traceLock = NSLock()
    private var traceLines: [String] = []
    private func trace(_ s: String) {
        traceLock.lock()
        traceLines.append(s)
        if traceLines.count > 32 { traceLines.removeFirst(traceLines.count - 32) }
        traceLock.unlock()
    }
    func dumpTrace() -> [String] {
        traceLock.lock(); defer { traceLock.unlock() }
        return traceLines
    }

    init(device: IOHIDDevice, runLoop: CFRunLoop) {
        self.device = device
        self.runLoop = runLoop
    }

    deinit { inputBuffer?.deallocate() }

    // MARK: Propriedades

    var vendorId: Int { (IOHIDDeviceGetProperty(device, "VendorID" as CFString) as? NSNumber)?.intValue ?? 0 }
    var productId: Int { (IOHIDDeviceGetProperty(device, "ProductID" as CFString) as? NSNumber)?.intValue ?? 0 }
    var usagePage: Int { (IOHIDDeviceGetProperty(device, "PrimaryUsagePage" as CFString) as? NSNumber)?.intValue ?? 0 }
    var usage: Int { (IOHIDDeviceGetProperty(device, "PrimaryUsage" as CFString) as? NSNumber)?.intValue ?? 0 }
    var transport: String { (IOHIDDeviceGetProperty(device, "Transport" as CFString) as? String) ?? "?" }
    var productName: String { (IOHIDDeviceGetProperty(device, "Product" as CFString) as? String) ?? "<\(vidpid)>" }
    var serial: String { (IOHIDDeviceGetProperty(device, "SerialNumber" as CFString) as? String) ?? "-" }
    var vidpid: String { String(format: "0x%04x/0x%04x", vendorId, productId) }
    var builtIn: Bool { (IOHIDDeviceGetProperty(device, "Built-In" as CFString) as? NSNumber)?.boolValue ?? false }
    var locationId: Int { (IOHIDDeviceGetProperty(device, "LocationID" as CFString) as? NSNumber)?.intValue ?? 0 }
    var maxIn: Int { (IOHIDDeviceGetProperty(device, "MaxInputReportSize" as CFString) as? NSNumber)?.intValue ?? 0 }
    var maxOut: Int { (IOHIDDeviceGetProperty(device, "MaxOutputReportSize" as CFString) as? NSNumber)?.intValue ?? 0 }
    var maxFeat: Int { (IOHIDDeviceGetProperty(device, "MaxFeatureReportSize" as CFString) as? NSNumber)?.intValue ?? 0 }

    var desc: String {
        "\(productName) [\(transport), \(vidpid), usage 0x\(String(usagePage, radix: 16))/0x\(String(usage, radix: 16)), loc 0x\(String(locationId, radix: 16)), maxReport in=\(maxIn) out=\(maxOut) feat=\(maxFeat), sn \(serial)]"
    }
}

extension HIDDeviceBridge: CustomStringConvertible {
    var description: String { desc }

    // MARK: Ciclo

    func open() throws {
        guard !opened else { return }
        let r = IOHIDDeviceOpen(device, 0) // kIOHIDOptionsTypeNone (compartilhado)
        guard r == kIOReturnSuccess else { throw HIDBridgeError.openFailed(r) }
        opened = true

        IOHIDDeviceScheduleWithRunLoop(device, runLoop, "kCFRunLoopDefaultMode" as CFString)

        // O buffer precisa comportar o maior report da interface, e o receptor Compx declara reports de 49 bytes.
        let inputLen = max(64, maxIn)
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: inputLen)
        buf.initialize(repeating: 0, count: inputLen)
        inputBuffer = buf
        IOHIDDeviceRegisterInputReportCallback(
            device, buf, CFIndex(inputLen),
            { ctxPtr, _result, _sender, _type, _reportID, report, reportLength in
                guard let ctx = ctxPtr, reportLength > 3 else { return }
                let me = Unmanaged<HIDDeviceBridge>.fromOpaque(ctx).takeUnretainedValue()
                var body = Array(UnsafeBufferPointer(start: report, count: reportLength))
                let rid = UInt8(truncatingIfNeeded: _reportID)
                // O callback às vezes entrega o payload sem o report id (o id vem no argumento).
                if (rid == 0x10 || rid == 0x11 || rid == 0x20), body.first != rid {
                    body.insert(rid, at: 0)
                }
                me.trace("IN len=\(body.count) [\(body.prefix(12).map { String(format: "%02x", $0) }.joined(separator: " "))…]")
                me.inLock.lock()
                me.inputBodies.append(body)
                if me.inputBodies.count > 24 { me.inputBodies.removeFirst(me.inputBodies.count - 24) }
                me.inLock.unlock()
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    /// Formas de passar o report ID no IOKit (variam por driver/descriptor).
    enum ReportIDMode: String, CaseIterable {
        case separate       // param=id, buffer SEM id (hidapi-style)
        case embedded       // param=0, buffer COM id em [0] (hidraw-style)
        case embeddedAndParam // param=id, buffer COM id também
    }

    /// Envia request HID++ (corpo SEM report id) por um dos report types.
    func setReport(_ type: IOHIDReportType, reportID: UInt8, body: [UInt8],
                   mode: ReportIDMode = .separate) throws {
        var out = body
        let idParam: UInt8
        switch mode {
        case .separate: idParam = reportID
        case .embedded: out.insert(reportID, at: 0); idParam = 0
        case .embeddedAndParam: out.insert(reportID, at: 0); idParam = reportID
        }
        let r = out.withUnsafeMutableBufferPointer { bp -> IOReturn in
            guard let base = bp.baseAddress else { return kIOReturnNoMemory }
            return IOHIDDeviceSetReport(device, type, Int(idParam), base, CFIndex(bp.count))
        }
        trace("SET type=\(reportTypeTag(type)) id=0x\(String(reportID, radix: 16)) mode=\(mode.rawValue) len=\(out.count) → ior=0x\(String(UInt32(bitPattern: r), radix: 16))")
        guard r == kIOReturnSuccess else { throw HIDBridgeError.setReportFailed(r, length: out.count) }
    }

    private func reportTypeTag(_ t: IOHIDReportType) -> String {
        if t == kIOHIDReportTypeFeature { return "feature" }
        if t == kIOHIDReportTypeOutput { return "output" }
        return "input"
    }

    /// IOHIDDeviceGetReport(.feature): lê a resposta enfileirada (vazio se ainda não pronta).
    func getFeatureReport(reportID: UInt8, size: Int) -> (ior: IOReturn, data: [UInt8]) {
        var len = CFIndex(size)
        var buf = [UInt8](repeating: 0, count: size)
        let r: IOReturn = buf.withUnsafeMutableBufferPointer { bp -> IOReturn in
            guard let base = bp.baseAddress else { return kIOReturnNoMemory }
            return IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, Int(reportID), base, &len)
        }
        guard r == kIOReturnSuccess, len > 0, len <= buf.count else {
            trace("GET id=0x\(String(reportID, radix: 16)) → ior=0x\(String(UInt32(bitPattern: r), radix: 16)) len=0")
            return (r, [])
        }
        let data = Array(buf.prefix(Int(len)))
        trace("GET id=0x\(String(reportID, radix: 16)) → len=\(len) [\(data.prefix(12).map { String(format: "%02x", $0) }.joined(separator: " "))…]")
        return (r, data)
    }

    func drainInputBodies() -> [[UInt8]] {
        inLock.lock()
        let out = inputBodies
        inputBodies.removeAll()
        inLock.unlock()
        return out
    }
}
