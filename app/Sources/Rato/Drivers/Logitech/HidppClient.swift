import Foundation

/// Cliente HID++ v2 sobre uma interface Logitech.
/// Payload (corpo, SEM report id): [devIdx, featureIdx, (funcIdx<<4), params...]
/// Curto 0x10 = 3 params (wire 7 com id). Longo 0x11 = 16 params (wire 20 com id).
/// No macOS o id vai no byte 0 e no argumento de IOHIDDeviceSetReport.
///
/// Transporte:
///  - .featureReport : SET_REPORT(feature 0x10/0x11) + GET_REPORT(feature)   (receivers costumam gostar)
///  - .outputInput   : SET/OUT(output 0x10/0x11) + resposta por INPUT report (mice diretos costumam gostar)
/// O handshake testa os dois e fixa o que funcionar.
final class HidppClient: @unchecked Sendable {
    enum Transport: String { case featureReport, outputInput }

    private let bridge: HIDDeviceBridge
    /// 0xFF = conexão direta USB/BT; 1..6 = slots de receptor.
    var deviceIndex: UInt8
    let devLabel: String
    private(set) var transport: Transport = .outputInput
    /// Apple: o report ID vai no argumento E no byte 0. `.separate` faz o IOHID
    /// sobrescrever o device index (sentinela: resp[1] == req[2]).
    private(set) var idMode: HIDDeviceBridge.ReportIDMode = .embeddedAndParam

    private let lock = NSLock()
    /// Serializa backup, escrita e conferência de setor do 0x8100.
    let profileLock = NSLock()
    private var featureIndexCache: [UInt16: FeatureRef] = [:]

    struct FeatureRef: CustomStringConvertible, Equatable {
        let index: UInt8
        let version: UInt8
        var description: String { String(format: "idx=0x%02x v%u", index, version) }
    }

    init(bridge: HIDDeviceBridge, deviceIndex: UInt8, devLabel: String, transport: Transport = .featureReport) {
        self.bridge = bridge
        self.deviceIndex = deviceIndex
        self.devLabel = devLabel
        self.transport = transport
    }

    var description: String {
        "\(devLabel) dev@\(deviceIndex == 0xff ? "0xff" : String(deviceIndex))@[\(transport.rawValue)/\(idMode.rawValue)]"
    }

    func setTransport(_ t: Transport, idMode: HIDDeviceBridge.ReportIDMode? = nil) {
        lock.lock()
        transport = t
        if let m = idMode { self.idMode = m }
        lock.unlock()
    }

    // MARK: Resposta

    struct Response {
        let body: [UInt8]                        // [devIdx, featureIdx, funcEcho, params...]
        var error20: UInt8? = nil                // erro HID++ 2.0: [devIdx, 0xFF, featureIdx, funcEcho, código]
        var p: [UInt8] { Array(body.dropFirst(3)) }
    }

    /// Procura o eco [devIdx, featureIdx, func<<4] (scan curto; bytes estritos).
    /// `accept` filtra respostas (ex.: exigir eco de param) para garimpagem anti-stale.
    static func match(body raw: [UInt8], against reqBody: [UInt8], rejectEcho: Bool = true,
                      accept: ((Response) -> Bool)? = nil) -> Response? {
        guard raw.count >= 4, reqBody.count >= 3 else { return nil }
        let off0: Int = (raw.first == 0x10 || raw.first == 0x11) ? 1 : 0
        guard raw.count - off0 >= 3 else { return nil }
        for off in off0...min(off0 + 3, raw.count - 3) {
            if off + 4 < raw.count, raw[off] == reqBody[0], raw[off + 1] == 0xff,
               raw[off + 2] == reqBody[1], raw[off + 3] == reqBody[2] {
                return Response(body: Array(raw[off...]), error20: raw[off + 4])
            }
            if raw[off] == reqBody[0],
               raw[off + 1] == reqBody[1],
               raw[off + 2] == reqBody[2] {
                let b = Array(raw[off...])
                let resp = Response(body: b)
                let reqParams = Array(reqBody.dropFirst(3))
                let respParams = Array(b.dropFirst(3))
                if rejectEcho, !reqParams.isEmpty,
                   respParams.elementsEqual(reqParams),
                   respParams.dropFirst(reqParams.count).allSatisfy({ $0 == 0x00 }) {
                    return nil // apenas eco do próprio SetReport
                }
                if let acc = accept, !acc(resp) { continue } // não confere: provavelmente stale
                return resp
            }
        }
        return nil
    }

    private func request(devIdx: UInt8, featureIdx: UInt8, funcIdx: UInt8,
                         params: [UInt8], timeoutMs: Int,
                         idMode: HIDDeviceBridge.ReportIDMode? = nil,
                         accept: ((Response) -> Bool)? = nil) throws -> Response {
        try bridge.open() // idempotente
        // HID++ curto: 3 params (wire 7 com report id). Longo: 16 params (wire 20).
        // 4+ params reais não cabem no curto — sobem para 0x11.
        let isLong = params.count > 3
        let slots = isLong ? 16 : 3
        var body = [devIdx, featureIdx, UInt8((funcIdx << 4) & 0xf0)]
        body.append(contentsOf: params.prefix(slots))
        while body.count < 3 + slots { body.append(0x00) }
        let id: UInt8 = isLong ? 0x11 : 0x10
        let ridMode = idMode ?? lockedIdMode()

        switch transport {
        case .featureReport:
            try bridge.setReport(kIOHIDReportTypeFeature, reportID: id, body: body, mode: ridMode)
        case .outputInput:
            try bridge.setReport(kIOHIDReportTypeOutput, reportID: id, body: body, mode: ridMode)
        }

        let mode = transport
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)

        while Date() < deadline {
            if mode == .featureReport {
                let size = isLong ? 26 : 14
                let gr = bridge.getFeatureReport(reportID: id, size: size)
                if gr.ior == kIOReturnSuccess, let rep = Self.match(body: gr.data, against: body, accept: accept) { return rep }
            } else {
                // outputInput: resposta vem por INPUT; tenta GET(feature) também, por garantia
                let gr = bridge.getFeatureReport(reportID: id, size: isLong ? 26 : 14)
                if gr.ior == kIOReturnSuccess, let rep = Self.match(body: gr.data, against: body, accept: accept) { return rep }
            }
            // Input report nunca traz o eco do próprio pedido; só o GET_REPORT traz.
            for raw in bridge.drainInputBodies() {
                if let rep = Self.match(body: raw, against: body, rejectEcho: false, accept: accept) { return rep }
            }
            Thread.sleep(forTimeInterval: 0.03)
        }
        throw HidppError.noResponse(function: Int(funcIdx), feature: UInt16(featureIdx))
    }

    private func lockedIdMode() -> HIDDeviceBridge.ReportIDMode {
        lock.lock(); defer { lock.unlock() }
        return idMode
    }

    /// Handshake completo: GetFeature(0x0001) votando transporte × modo de report-id.
    /// Padrão observado no G703/dongle LIGHTSPEED: o 1º round desperta a interface,
    /// o 2º é respondido — por isso outputInput roda em DUAS passadas.
    /// No primeiro acerto fixa (transport, idMode) no client e retorna true.
    func probeHandshake(timeoutMs: Int = 350, verify: Bool = true) -> Bool {
        // limpa notificações não solicitadas acumuladas
        _ = bridge.drainInputBodies()
        // embeddedAndParam primeiro: é o contrato do IOHIDDeviceSetReport no macOS.
        let modes: [HIDDeviceBridge.ReportIDMode] = [.embeddedAndParam, .embedded, .separate]
        var attempts: [(Transport, HIDDeviceBridge.ReportIDMode)] = []
        for _ in 0...1 {
            for m in modes { attempts.append((.outputInput, m)) }
        }
        for m in modes { attempts.append((.featureReport, m)) }

        for (t, m) in attempts {
            setTransport(t, idMode: m)
            guard let resp = try? request(devIdx: deviceIndex, featureIdx: 0, funcIdx: 0,
                                          params: [0x00, 0x01], timeoutMs: timeoutMs, idMode: m)
            else { continue }
            setTransport(t, idMode: m)
            lastHandshake = hex(resp.body, cap: 8)
            if verify && (try? feature(HidppFeature.featureSet.rawValue)) == nil {
                // falso positivo (eco/notificação) — desfaz
                invalidateFeatureCache()
                continue
            }
            return true
        }
        return false
    }

    /// Último corpo de handshake bem-sucedido (para logs).
    var lastHandshake: String?

    // MARK: Call pública

    private func throwIfError(_ resp: Response, feature: UInt16, funcIdx: UInt8) throws -> Response {
        if resp.p.first == 0x8f {
            throw HidppError.deviceError(code: 0x8f, feature: feature, function: Int(funcIdx))
        }
        return resp
    }

    func call(featureIndex: UInt8, featureId: UInt16, funcIdx: UInt8, params: [UInt8],
              timeoutMs: Int = 450, accept: ((Response) -> Bool)? = nil) throws -> Response {
        let resp = try request(devIdx: deviceIndex, featureIdx: featureIndex, funcIdx: funcIdx,
                               params: params, timeoutMs: timeoutMs, accept: accept)
        if let code = resp.error20 {
            throw HidppError.deviceError20(code: code, feature: featureId, function: Int(funcIdx))
        }
        guard resp.body.count >= 4 else { throw HidppError.unexpectedBody(resp.body) }
        let echoOk = resp.body[1] == featureIndex && (resp.body[2] & 0xf0) == UInt8((funcIdx << 4) & 0xf0)
        guard echoOk || (resp.body[1] == 0x00 && resp.body[2] == 0x00) else {
            throw HidppError.unexpectedBody(resp.body)
        }
        return try throwIfError(resp, feature: featureId, funcIdx: funcIdx)
    }

    // MARK: Descoberta de feature

    private func featureUncached(_ id: UInt16) throws -> FeatureRef {
        let resp = try call(featureIndex: 0x00, featureId: 0x0000, funcIdx: 0,
                            params: [UInt8(id >> 8), UInt8(id & 0xff)], timeoutMs: 600)
        guard resp.body.count >= 5 else { throw HidppError.unexpectedBody(resp.body) }
        let idx = resp.body[3]
        let ver = resp.body[4]
        guard idx != 0x00 else { throw HidppError.deviceError(code: 0x01, feature: id, function: 0) }
        return FeatureRef(index: idx, version: ver)
    }

    func feature(_ id: UInt16) throws -> FeatureRef {
        lock.lock()
        if let hit = featureIndexCache[id] { lock.unlock(); return hit }
        lock.unlock()
        let ref = try featureUncached(id)
        lock.lock()
        featureIndexCache[id] = ref
        lock.unlock()
        return ref
    }

    func tryFeature(_ id: UInt16) -> FeatureRef? { try? feature(id) }

    func invalidateFeatureCache() {
        lock.lock()
        featureIndexCache.removeAll()
        lock.unlock()
    }

    var cachedFeatureCount: Int {
        lock.lock(); defer { lock.unlock() }
        return featureIndexCache.count
    }

    func cachedFeatures() -> [UInt16: FeatureRef] {
        lock.lock(); defer { lock.unlock() }
        return featureIndexCache
    }
}
