import Darwin
import System

extension FileDescriptor {
    func setNonBlocking() throws {
        let flags = fcntl(rawValue, F_GETFL)
        guard flags >= 0 else { throw Errno(rawValue: errno) }
        guard fcntl(rawValue, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw Errno(rawValue: errno)
        }
    }

    func setNoSigPipe() throws {
        guard fcntl(rawValue, F_SETNOSIGPIPE, 1) >= 0 else {
            throw Errno(rawValue: errno)
        }
    }

    func setCloseOnExec() throws {
        guard fcntl(rawValue, F_SETFD, FD_CLOEXEC) >= 0 else {
            throw Errno(rawValue: errno)
        }
    }
}
