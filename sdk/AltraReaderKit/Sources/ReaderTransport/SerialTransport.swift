#if os(macOS)
import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Discovers candidate serial devices for the reader-connection picker.
///
/// macOS exposes USB-serial adapters as `/dev/cu.*` (call-out, preferred for
/// applications that initiate the connection — unlike `/dev/tty.*`, `cu.*` does not
/// block waiting for carrier-detect, which matters for RS232-over-USB readers).
public enum SerialDeviceDiscovery {
    public static func candidateDevices() -> [String] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: "/dev") else { return [] }
        return entries
            .filter { $0.hasPrefix("cu.") }
            .filter { !$0.contains("Bluetooth") } // near-never the reader; keeps the picker short
            .sorted()
            .map { "/dev/" + $0 }
    }
}

/// A `Transport` over a macOS serial device (`/dev/cu.*`) using POSIX `termios`.
///
/// This is a generic byte pipe: it opens the device, configures baud/parity/stop
/// bits, and moves bytes in both directions. It has no knowledge of the Altra
/// Waves protocol — that belongs entirely to `ReaderProtocol`.
///
/// macOS notes:
/// - Requires the FTDI/Prolific/CH340-class VCP driver for the specific USB-serial
///   chipset to be installed (see `Documentation/USER_GUIDE.md`).
/// - No special entitlement is required for `/dev/cu.*` access in a non-sandboxed
///   app; a sandboxed build needs `com.apple.security.device.serial`.
/// - Handles device unplug via a `DispatchSourceRead` cancellation callback, not
///   polling.
public final class SerialTransport: Transport, @unchecked Sendable {
    private let path: String
    private let baudRate: Int
    private var fileDescriptor: Int32 = -1
    private var readSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.altrareaderkit.serial", qos: .userInitiated)
    private let lock = NSLock()
    private var _state: TransportState = .disconnected
    private var continuation: AsyncStream<TransportEvent>.Continuation?

    public private(set) var state: TransportState {
        get { lock.withLock { _state } }
        set {
            lock.withLock { _state = newValue }
            continuation?.yield(.stateChanged(newValue))
        }
    }

    public let events: AsyncStream<TransportEvent>

    public init(path: String, baudRate: Int = 115_200) {
        self.path = path
        self.baudRate = baudRate
        var cont: AsyncStream<TransportEvent>.Continuation!
        self.events = AsyncStream { c in cont = c }
        self.continuation = cont
    }

    public func connect(timeout: TimeInterval) async throws {
        guard fileDescriptor < 0 else { throw TransportError.alreadyConnected }
        state = .connecting

        let fd = open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else {
            let reason = String(cString: strerror(errno))
            state = .error(reason)
            throw TransportError.connectionFailed("open(\(path)) failed: \(reason)")
        }

        guard let speed = Self.speed(for: baudRate) else {
            close(fd)
            state = .error("unsupported baud rate")
            throw TransportError.connectionFailed("Unsupported baud rate \(baudRate)")
        }

        var options = termios()
        tcgetattr(fd, &options)
        cfsetispeed(&options, speed)
        cfsetospeed(&options, speed)

        // 8N1, raw mode, no flow control — the common default for these UHF reader
        // modules per the reference app's serial settings; adjust per your module's
        // documented UART configuration if different.
        options.c_cflag |= tcflag_t(CS8 | CLOCAL | CREAD)
        options.c_cflag &= ~tcflag_t(PARENB | CSTOPB | CSIZE)
        options.c_cflag |= tcflag_t(CS8)
        options.c_lflag &= ~tcflag_t(ICANON | ECHO | ECHOE | ISIG)
        options.c_iflag &= ~tcflag_t(IXON | IXOFF | IXANY)
        options.c_oflag &= ~tcflag_t(OPOST)
        options.c_cc.16 = 0 // VMIN
        options.c_cc.17 = 1 // VTIME (100ms granularity read timeout at the driver level)

        tcsetattr(fd, TCSANOW, &options)
        tcflush(fd, TCIOFLUSH)

        self.fileDescriptor = fd
        startReadSource(fd: fd)
        state = .connected
    }

    public func disconnect() async {
        readSource?.cancel()
        readSource = nil
        if fileDescriptor >= 0 {
            close(fileDescriptor)
            fileDescriptor = -1
        }
        state = .disconnected
    }

    public func write(_ bytes: [UInt8]) async throws {
        guard fileDescriptor >= 0 else { throw TransportError.notConnected }
        let result = bytes.withUnsafeBufferPointer { buf -> Int in
            guard let base = buf.baseAddress else { return 0 }
            return Darwin.write(fileDescriptor, base, buf.count)
        }
        if result < 0 {
            let reason = String(cString: strerror(errno))
            throw TransportError.writeFailed(reason)
        }
    }

    private func startReadSource(fd: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 512)
            let n = buffer.withUnsafeMutableBufferPointer { ptr -> Int in
                guard let base = ptr.baseAddress else { return 0 }
                return read(fd, base, ptr.count)
            }
            if n > 0 {
                self.continuation?.yield(.bytesReceived(Array(buffer.prefix(n))))
            } else if n == 0 {
                // EOF — device likely removed.
                self.continuation?.yield(.deviceRemoved)
                self.state = .error(TransportError.deviceRemoved.description)
            }
        }
        source.setCancelHandler { [weak self] in
            self?.continuation?.finish()
        }
        source.resume()
        self.readSource = source
    }

    private static func speed(for baud: Int) -> speed_t? {
        switch baud {
        case 9600: return speed_t(B9600)
        case 19200: return speed_t(B19200)
        case 38400: return speed_t(B38400)
        case 57600: return speed_t(B57600)
        case 115200: return speed_t(B115200)
        case 230400: return speed_t(B230400)
        default: return nil
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock(); defer { unlock() }
        return body()
    }
}
#endif
