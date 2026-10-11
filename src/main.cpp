#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cerrno>
#include <csignal>
#include <cstring>
#include <filesystem>
#include <iostream>
#include <string>

namespace {
volatile std::sig_atomic_t stopping = 0;
void stop_handler(int) { stopping = 1; }

bool send_all(int socket, const std::string& message) {
    std::size_t sent = 0;
    while (sent < message.size()) {
        const auto count = send(socket, message.data() + sent,
                                message.size() - sent, MSG_NOSIGNAL);
        if (count < 0 && errno == EINTR && !stopping) continue;
        if (count <= 0) return false;
        sent += static_cast<std::size_t>(count);
    }
    return true;
}
}

int main(int argc, char* argv[]) {
    int port = 8080;
    std::string data_dir = "./data";

    for (int i = 1; i < argc; ++i) {
        const std::string argument = argv[i];
        if (argument == "--help") {
            std::cout << "Usage: app [--port 1024..65535] [--data-dir PATH]\n";
            return 0;
        }
        if ((argument != "--port" && argument != "--data-dir") || i + 1 >= argc) {
            std::cerr << "Unknown argument or missing value: " << argument << '\n';
            return 1;
        }
        const std::string value = argv[++i];
        if (argument == "--data-dir") {
            data_dir = value;
        } else {
            try {
                if (value.empty() || value.find_first_not_of("0123456789") != std::string::npos)
                    throw std::invalid_argument("digits required");
                port = std::stoi(value);
                if (port < 1024 || port > 65535) throw std::out_of_range("port");
            } catch (const std::exception&) {
                std::cerr << "Port must be an integer from 1024 to 65535\n";
                return 1;
            }
        }
    }

    std::error_code error;
    if (!std::filesystem::is_directory(data_dir, error)) {
        std::cerr << "Data directory does not exist or is inaccessible: " << data_dir << '\n';
        return 1;
    }

    struct sigaction action {};
    action.sa_handler = stop_handler;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGTERM, &action, nullptr) != 0 ||
        sigaction(SIGINT, &action, nullptr) != 0) {
        std::cerr << "Cannot install signal handlers\n";
        return 1;
    }

    const int server = socket(AF_INET, SOCK_STREAM, 0);
    if (server < 0) {
        std::cerr << "socket: " << std::strerror(errno) << '\n';
        return 1;
    }
    const int reuse = 1;
    setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

    sockaddr_in address {};
    address.sin_family = AF_INET;
    address.sin_port = htons(static_cast<unsigned short>(port));
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(server, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0 ||
        listen(server, 16) != 0) {
        std::cerr << "bind/listen: " << std::strerror(errno) << '\n';
        close(server);
        return 1;
    }
    std::cout << "Listening on http://127.0.0.1:" << port
              << "\nData directory: " << data_dir << std::endl;

    while (!stopping) {
        const int client = accept(server, nullptr, nullptr);
        if (client < 0) {
            if (errno == EINTR) continue;
            std::cerr << "accept: " << std::strerror(errno) << '\n';
            close(server);
            return 1;
        }

        // Bound each client operation; this educational server handles one client at a time.
        timeval timeout {2, 0};
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        std::string request;
        char buffer[1024];
        while (!stopping && request.find("\r\n\r\n") == std::string::npos &&
               request.size() < 8192) {
            const auto count = recv(client, buffer, sizeof(buffer), 0);
            if (count <= 0) break;
            request.append(buffer, static_cast<std::size_t>(count));
        }

        if (!stopping && request.find("\r\n\r\n") != std::string::npos) {
            std::string status = "404 Not Found";
            std::string type = "text/plain; charset=utf-8";
            std::string body = "Not found\n";
            if (request.rfind("GET /health HTTP/", 0) == 0) {
                status = "200 OK";
                body = "ok\n";
            } else if (request.rfind("GET / HTTP/", 0) == 0) {
                status = "200 OK";
                type = "text/html; charset=utf-8";
                body = "<!doctype html><html lang=\"zh-CN\"><meta charset=\"utf-8\">"
                       "<title>部署实验</title><h1>部署成功！</h1>"
                       "<p>C++ 示例服务已启动。</p><a href=\"/health\">健康检查</a></html>";
            }
            send_all(client, "HTTP/1.1 " + status + "\r\nContent-Type: " + type +
                     "\r\nContent-Length: " + std::to_string(body.size()) +
                     "\r\nConnection: close\r\n\r\n" + body);
        }
        close(client);
    }

    close(server);
    std::cout << "Service stopped" << std::endl;
    return 0;
}
