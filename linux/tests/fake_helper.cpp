// A stand-in for the Swift helper in the native containment tests: it answers the handshake and
// heartbeats, and with --spawn-child starts a long-running child and reports its PID as an event
// frame, so tests can check that ending the helper's unit ends its descendants too.
#include <cstdio>
#include <cstring>
#include <iostream>
#include <string>
#include <unistd.h>

int main(int argc, char **argv) {
    bool spawnChild = argc > 1 && std::strcmp(argv[1], "--spawn-child") == 0;
    if (spawnChild) {
        pid_t child = fork();
        if (child == 0) {
            execlp("sleep", "sleep", "300", static_cast<char *>(nullptr));
            _exit(127);
        }
        std::cout << "{\"type\":\"event\",\"sequence\":1,\"workflow\":\"test\",\"name\":\"child\",\"fields\":{\"pid\":\""
                  << child << "\",\"helper\":\"" << getpid() << "\"}}" << std::endl;
    } else {
        std::cout << "{\"type\":\"event\",\"sequence\":1,\"workflow\":\"test\",\"name\":\"started\",\"fields\":{\"helper\":\""
                  << getpid() << "\"}}" << std::endl;
    }
    std::string line;
    while (std::getline(std::cin, line)) {
        if (line.find("\"hello\"") != std::string::npos) {
            std::cout << "{\"type\":\"welcome\",\"build\":\"test-build\"}" << std::endl;
        } else if (line.find("\"heartbeat\"") != std::string::npos) {
            auto at = line.find("\"sequence\":");
            std::cout << "{\"type\":\"heartbeat\",\"sequence\":" << std::atoi(line.c_str() + at + 11) << "}" << std::endl;
        } else if (line.find("\"shutdown\"") != std::string::npos) {
            return 0;
        }
    }
    return 0;
}
