import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Minimal POSIX serial port (macOS + Linux). Works with the STM32's USB CDC port
/// (`/dev/cu.usbmodem…`) and with the virtual reader's pseudo-terminal (`/tmp/chipless-reader`).
/// A background thread reads incoming bytes and hands them to `onData`.
public final class SerialPort {
    public let path: String
    public let baudRate: Int
    public var onData: (([UInt8]) -> Void)?
    public var onClose: ((String) -> Void)?

    private var fd: Int32 = -1
    private var thread: Thread?
    private let stateLock = NSLock()
    private var running = false
    private var readerExited = DispatchSemaphore(value: 0)

    public init(path: String, baudRate: Int = 115_200) {
        self.path = path
        self.baudRate = baudRate
    }

    public var isOpen: Bool { stateLock.lock(); defer { stateLock.unlock() }; return fd >= 0 }

    /// Serial devices that look like a reader: USB CDC / USB-serial ports and the virtual reader.
    public static func candidatePorts() -> [String] {
        var out: [String] = []
        if let items = try? FileManager.default.contentsOfDirectory(atPath: "/dev") {
            for name in items.sorted() where name.hasPrefix("cu.usbmodem") || name.hasPrefix("cu.usbserial")
                || name.hasPrefix("ttyACM") || name.hasPrefix("ttyUSB") {
                out.append("/dev/" + name)
            }
        }
        if FileManager.default.fileExists(atPath: "/tmp/chipless-reader") { out.append("/tmp/chipless-reader") }
        return out
    }

    public func open() throws {
        guard !isOpen else { return }
        #if canImport(Darwin)
        let handle = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        #else
        let handle = Glibc.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        #endif
        guard handle >= 0 else { throw ChiplessError.openFailed("\(path): \(String(cString: strerror(errno)))") }

        var t = termios()
        if tcgetattr(handle, &t) == 0 {
            cfmakeraw(&t)
            let speed = SerialPort.speedConstant(baudRate)
            cfsetispeed(&t, speed)
            cfsetospeed(&t, speed)
            t.c_cflag |= tcflag_t(CLOCAL | CREAD)
            _ = tcsetattr(handle, TCSANOW, &t)       // a pty may refuse some flags - that's fine
        }
        tcflush(handle, TCIOFLUSH)

        stateLock.lock()
        fd = handle
        running = true
        readerExited = DispatchSemaphore(value: 0)
        let exited = readerExited
        stateLock.unlock()

        let th = Thread { [weak self] in
            defer { exited.signal() }
            self?.readLoop(handle)
        }
        th.name = "ChiplessKit.SerialPort"
        th.start()
        thread = th
    }

    public func close() {
        stateLock.lock()
        let handle = fd
        let wasRunning = running
        running = false
        let exited = readerExited
        stateLock.unlock()
        // Wait for the reader thread to leave poll()/read() before closing the descriptor:
        // the OS reuses descriptor numbers, and a straggling thread would otherwise steal the
        // bytes of the next port opened (e.g. right after probing).
        if wasRunning, let t = thread, t != Thread.current {
            _ = exited.wait(timeout: .now() + 1.0)
        }
        stateLock.lock()
        fd = -1
        stateLock.unlock()
        if handle >= 0 {
            #if canImport(Darwin)
            _ = Darwin.close(handle)
            #else
            _ = Glibc.close(handle)
            #endif
        }
    }

    public func write(_ bytes: [UInt8]) throws {
        stateLock.lock()
        let handle = fd
        stateLock.unlock()
        guard handle >= 0 else { throw ChiplessError.notConnected }
        var offset = 0
        var spins = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBufferPointer { buf -> Int in
                #if canImport(Darwin)
                return Darwin.write(handle, buf.baseAddress, buf.count)
                #else
                return Glibc.write(handle, buf.baseAddress, buf.count)
                #endif
            }
            if n > 0 { offset += n; continue }
            if n < 0 && (errno == EAGAIN || errno == EINTR) && spins < 2000 {
                spins += 1
                usleep(500)
                continue
            }
            throw ChiplessError.writeFailed(String(cString: strerror(errno)))
        }
    }

    private func readLoop(_ handle: Int32) {
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            stateLock.lock()
            let keepGoing = running
            stateLock.unlock()
            guard keepGoing else { return }

            var p = pollfd(fd: handle, events: Int16(POLLIN), revents: 0)
            let r = poll(&p, 1, 100)
            if r <= 0 { continue }
            if (p.revents & Int16(POLLNVAL)) != 0 { return }
            let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
                #if canImport(Darwin)
                return Darwin.read(handle, ptr.baseAddress, ptr.count)
                #else
                return Glibc.read(handle, ptr.baseAddress, ptr.count)
                #endif
            }
            if n > 0 {
                stateLock.lock()
                let stillOpen = running
                stateLock.unlock()
                if !stillOpen { return }
                onData?(Array(buf[0..<n]))
            } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
                // USB unplugged (macOS returns -1/ENXIO or 0) or the virtual reader was stopped
                let reason = n == 0 ? "end of file" : String(cString: strerror(errno))
                stateLock.lock()
                let wasRunning = running
                stateLock.unlock()
                if wasRunning {
                    close()
                    onClose?(reason)
                }
                return
            }
        }
    }

    private static func speedConstant(_ baud: Int) -> speed_t {
        switch baud {
        case 9600: return speed_t(B9600)
        case 19200: return speed_t(B19200)
        case 38400: return speed_t(B38400)
        case 57600: return speed_t(B57600)
        case 230400: return speed_t(B230400)
        default: return speed_t(B115200)
        }
    }
}
