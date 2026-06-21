// Minimal ORC executor for the iOS simulator: the standalone analog of the
// in-app iOS JIT host. Runs a SimpleRemoteEPCServer (see server.cpp) so the
// macOS daemon can link and run objects remotely inside a simulator process.
// Unlike the macOS agent it cannot inherit a socketpair fd (simctl spawn
// launches it in the simulator's process domain), so it connects out over TCP
// loopback, which the simulator shares with the host.

#include "server.h"

#include <CoreFoundation/CoreFoundation.h>
#include <arpa/inet.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <netinet/in.h>
#include <string>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>

static void printErrorAndExit(const char *msg) {
  fprintf(stderr, "iossim-executor error: %s\n\nUsage:\n  iossim-executor port=<tcp-port>\n",
          msg);
  exit(1);
}

static int connectLoopback(int port) {
  int fd = socket(AF_INET, SOCK_STREAM, 0);
  if (fd < 0)
    printErrorAndExit("socket failed");
  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_port = htons(static_cast<uint16_t>(port));
  if (inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr) != 1)
    printErrorAndExit("inet_pton failed");
  if (connect(fd, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) != 0)
    printErrorAndExit("connect failed");
  return fd;
}

int main(int argc, char *argv[]) {
  dlopen("/usr/lib/swift/libswiftCore.dylib", RTLD_NOW | RTLD_GLOBAL);
  dlopen("/usr/lib/swift/libswift_Concurrency.dylib", RTLD_NOW | RTLD_GLOBAL);
  dlopen("/usr/lib/swift/libswiftFoundation.dylib", RTLD_NOW | RTLD_GLOBAL);
  dlopen("/usr/lib/swift/libswiftDispatch.dylib", RTLD_NOW | RTLD_GLOBAL);
  dlopen("/System/Library/Frameworks/UIKit.framework/UIKit",
         RTLD_NOW | RTLD_GLOBAL);
  dlopen("/System/Library/Frameworks/SwiftUI.framework/SwiftUI",
         RTLD_NOW | RTLD_GLOBAL);

  if (argc != 2)
    printErrorAndExit("expected exactly one argument");

  const char *arg = argv[1];
  const char *eq = strchr(arg, '=');
  if (!eq || strncmp(arg, "port", static_cast<size_t>(eq - arg)) != 0)
    printErrorAndExit("expected port=<tcp-port>");
  int Port = atoi(eq + 1);
  if (Port <= 0)
    printErrorAndExit("invalid port");

  int FD = connectLoopback(Port);

  std::thread ServerThread([FD] {
    previewsmcp_ios_executor_start(FD, FD);
    std::_Exit(0);
  });
  ServerThread.detach();

  // Drain the main run loop (and with it the main dispatch queue) so
  // run_on_main's dispatch_sync target executes, mirroring PreviewAgent.
  while (true)
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.25, false);
}
