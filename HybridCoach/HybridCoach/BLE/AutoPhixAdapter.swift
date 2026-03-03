import Foundation
import CoreBluetooth

/// Adapter for the AutoPhix 3210 OBD-II scanner.
///
/// Despite advertising as "Autophix 3210", protocol analysis confirmed this is an
/// ELM327 v1.5 clone behind a standard FFF0/FFF1/FFF2 BLE GATT profile.
/// Known quirks vs genuine ELM327:
/// - ATS0 (spaces off) not supported — returns "?"
/// - ATRV (read voltage) not supported — returns "?"
/// - AT@1 (device description) not supported — returns "?"
/// - All other standard AT commands work normally
///
/// Strategy: probe with ATZ, and if ELM327-compatible, delegate to ELM327Adapter.
final class AutoPhixAdapter: OBDAdapter, @unchecked Sendable {

    private(set) var state: AdapterState = .disconnected
    let adapterType: AdapterType = .autoPhix

    private var peripheral: CBPeripheral?
    private var writeChar: CBCharacteristic?
    private var notifyChar: CBCharacteristic?

    private var responseBuffer = Data()
    private var responseContinuation: CheckedContinuation<Data, Error>?
    private var dataObserver: NSObjectProtocol?

    /// If true, the AutoPhix responds to ELM327 commands and we delegate to an internal ELM327 adapter.
    private var isELM327Compatible = false
    private var elm327Fallback: ELM327Adapter?

    // MARK: - OBDAdapter Protocol

    func configure(peripheral: CBPeripheral, writeCharacteristic: CBCharacteristic, notifyCharacteristic: CBCharacteristic) {
        self.peripheral = peripheral
        self.writeChar = writeCharacteristic
        self.notifyChar = notifyCharacteristic
        state = .connectedToAdapter

        dataObserver = NotificationCenter.default.addObserver(
            forName: .init("OBDDataReceived"), object: nil, queue: .main
        ) { [weak self] notification in
            if let data = notification.userInfo?["data"] as? Data {
                self?.didReceiveData(data)
            }
        }
    }

    func initialize() async throws {
        state = .initializing

        // The AutoPhix 3210 is confirmed as an ELM327 v1.5 clone.
        // Probe with ATZ to verify, then delegate to ELM327Adapter.
        print("AutoPhix: Probing with ELM327 ATZ...")
        do {
            let response = try await sendRawCommand(Data("ATZ\r".utf8), timeout: 3.0)
            let responseStr = String(data: response, encoding: .ascii) ?? ""
            print("AutoPhix: ATZ response: \(responseStr.replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n"))")

            if responseStr.contains("ELM") || responseStr.contains("OK") || responseStr.contains(">") {
                // Confirmed ELM327 compatible
                print("AutoPhix: ELM327 v1.5 clone detected — delegating to ELM327Adapter")
                isELM327Compatible = true

                guard let peripheral, let writeChar, let notifyChar else {
                    throw OBDAdapterError.notConnected
                }

                // Remove our own data observer before handing off to ELM327Adapter
                // (ELM327Adapter will register its own observer)
                if let observer = dataObserver {
                    NotificationCenter.default.removeObserver(observer)
                    dataObserver = nil
                }

                let elm = ELM327Adapter()
                elm.configure(
                    peripheral: peripheral,
                    writeCharacteristic: writeChar,
                    notifyCharacteristic: notifyChar
                )
                elm327Fallback = elm

                try await elm.initialize()
                state = elm.state
                return
            }
        } catch {
            print("AutoPhix: ELM327 probe failed — \(error.localizedDescription)")
        }

        // If ATZ probe didn't confirm ELM327, open the protocol analyzer for investigation
        state = .error("AutoPhix adapter did not respond to ELM327 probe. Use Protocol Analyzer to investigate.")
        throw OBDAdapterError.protocolError(
            "AutoPhix adapter did not respond as expected. " +
            "Open the Protocol Analyzer from the Connection tab to investigate the adapter's protocol."
        )
    }

    func sendPID(_ pid: String) async throws -> [UInt8] {
        if isELM327Compatible, let elm = elm327Fallback {
            return try await elm.sendPID(pid)
        }
        throw OBDAdapterError.protocolError("AutoPhix proprietary protocol — PID request not supported")
    }

    func didReceiveData(_ data: Data) {
        if isELM327Compatible {
            elm327Fallback?.didReceiveData(data)
            return
        }

        responseBuffer.append(data)

        // For raw binary mode, wait for a reasonable response
        // AutoPhix might terminate with specific bytes or after a timeout
        responseContinuation?.resume(returning: responseBuffer)
        responseBuffer = Data()
        responseContinuation = nil
    }

    func disconnect() {
        if let observer = dataObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        elm327Fallback?.disconnect()
        state = .disconnected
    }

    // MARK: - Private

    private func sendRawCommand(_ commandData: Data, timeout: TimeInterval) async throws -> Data {
        guard peripheral != nil, writeChar != nil else {
            throw OBDAdapterError.notConnected
        }

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      let peripheral = self.peripheral,
                      let writeChar = self.writeChar else {
                    continuation.resume(throwing: OBDAdapterError.notConnected)
                    return
                }

                self.responseBuffer = Data()
                self.responseContinuation = continuation

                let writeType: CBCharacteristicWriteType =
                    writeChar.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse

                peripheral.writeValue(commandData, for: writeChar, type: writeType)

                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                    guard let self, self.responseContinuation != nil else { return }
                    let buffered = self.responseBuffer
                    self.responseBuffer = Data()
                    if buffered.isEmpty {
                        self.responseContinuation?.resume(throwing: OBDAdapterError.timeout)
                    } else {
                        self.responseContinuation?.resume(returning: buffered)
                    }
                    self.responseContinuation = nil
                }
            }
        }
    }
}
