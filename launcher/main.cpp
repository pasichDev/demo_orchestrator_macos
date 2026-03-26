#include <chrono>
#include <csignal>
#include <fcntl.h>
#include <fstream>
#include <iostream>
#include <limits.h>
#include <mach-o/dyld.h>
#include <map>
#include <signal.h>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <sys/wait.h>
#include <thread>
#include <unistd.h>
#include <vector>

struct Config {
  int port = 8383;
  int max_restarts = 5;
  int health_check_interval_ms = 5000;
};

struct Process {
  std::string name;
  std::string path;
  std::vector<std::string> args;
  pid_t pid = 0;
  bool restart_on_fail = false;
  int restart_attempts = 0;
  int max_restarts = 5;
  std::string log_file;
  bool is_master = false;
  std::chrono::steady_clock::time_point last_start_time;
  int current_backoff_ms = 0;
};

std::vector<Process> processes;
bool running = true;
Config global_config;

// Simple JSON-ish parser for launcher_config.json
void load_config(const std::string &path) {
  std::ifstream file(path);
  if (!file.is_open())
    return;

  std::string line;
  while (std::getline(file, line)) {
    if (line.find("\"port\"") != std::string::npos) {
      size_t colon = line.find(":");
      global_config.port = std::stoi(line.substr(colon + 1));
    } else if (line.find("\"max_restarts\"") != std::string::npos) {
      size_t colon = line.find(":");
      global_config.max_restarts = std::stoi(line.substr(colon + 1));
    } else if (line.find("\"health_check_interval_ms\"") != std::string::npos) {
      size_t colon = line.find(":");
      global_config.health_check_interval_ms =
          std::stoi(line.substr(colon + 1));
    }
  }
}

void stop_all_processes() {
  for (auto &proc : processes) {
    if (proc.pid > 0) {
      kill(proc.pid, SIGTERM);
    }
  }
}

// SIGCHLD handler to reap zombies
void handle_sigchld(int sig) {
  int saved_errno = errno;
  while (waitpid(-1, nullptr, WNOHANG) > 0)
    ;
  errno = saved_errno;
}

void signal_handler(int signum) {
  running = false;
  stop_all_processes();
  exit(signum);
}

std::string get_executable_dir() {
  char path[PATH_MAX];
  uint32_t size = sizeof(path);
  if (_NSGetExecutablePath(path, &size) == 0) {
    std::string full_path(path);
    size_t last_slash = full_path.find_last_of("/");
    return full_path.substr(0, last_slash);
  }
  return ".";
}

void start_process(Process &proc) {
  proc.last_start_time = std::chrono::steady_clock::now();
  pid_t pid = fork();
  if (pid == 0) {
    // Redirect logs
    if (!proc.log_file.empty()) {
      int fd = open(proc.log_file.c_str(), O_WRONLY | O_CREAT | O_APPEND, 0644);
      if (fd != -1) {
        dup2(fd, STDOUT_FILENO);
        dup2(fd, STDERR_FILENO);
        close(fd);
      }
    }

    std::vector<char *> c_args;
    c_args.push_back(const_cast<char *>(proc.path.c_str()));
    for (const auto &arg : proc.args) {
      c_args.push_back(const_cast<char *>(arg.c_str()));
    }
    c_args.push_back(nullptr);

    execvp(proc.path.c_str(), c_args.data());
    exit(1);
  } else if (pid > 0) {
    proc.pid = pid;
    std::cout << "[Orchestrator] Launched " << proc.name << " (PID: " << pid
              << ")\n";
  }
}

bool check_health(int port) {
  std::string cmd =
      "curl -s -o /dev/null -w \"%{http_code}\" http://localhost:" +
      std::to_string(port) + "/health";
  FILE *pipe = popen(cmd.c_str(), "r");
  if (!pipe)
    return false;
  char buffer[128];
  std::string result = "";
  while (fgets(buffer, 128, pipe))
    result += buffer;
  pclose(pipe);
  return result == "200";
}

bool file_exists(const std::string &name) {
  struct stat buffer;
  return (stat(name.c_str(), &buffer) == 0);
}

int main(int argc, char *argv[]) {
  signal(SIGINT, signal_handler);
  signal(SIGTERM, signal_handler);

  // Setup SIGCHLD to prevent zombies
  struct sigaction sa;
  sa.sa_handler = &handle_sigchld;
  sigemptyset(&sa.sa_mask);
  sa.sa_flags = SA_RESTART | SA_NOCLDSTOP;
  if (sigaction(SIGCHLD, &sa, NULL) == -1) {
    perror("sigaction");
    return 1;
  }

  std::string base_dir = get_executable_dir();
  load_config(base_dir + "/launcher_config.json");

  std::string log_dir = base_dir + "/logs";
  mkdir(log_dir.c_str(), 0755);

  std::string backend_path = base_dir + "/bin/backend_bin";
  if (file_exists(backend_path)) {
    Process backend;
    backend.name = "Backend";
    backend.path = backend_path;
    backend.args = {"-port", std::to_string(global_config.port)};
    backend.restart_on_fail = true;
    backend.max_restarts = global_config.max_restarts;
    backend.log_file = log_dir + "/backend.log";
    backend.is_master = false;
    processes.push_back(backend);
  }

  std::string frontend_path = base_dir + "/app/app.app/Contents/MacOS/app";
  if (file_exists(frontend_path)) {
    Process frontend;
    frontend.name = "Frontend";
    frontend.path = frontend_path;
    frontend.args = {"--port=" + std::to_string(global_config.port)};
    frontend.restart_on_fail = false;
    frontend.log_file = log_dir + "/frontend.log";
    frontend.is_master = true;
    processes.push_back(frontend);
  }

  std::cout << "========================================\n";
  std::cout << "   SYSTEM ORCHESTRATOR v2.0      \n";
  std::cout << "   Config Port: " << global_config.port << "\n";
  std::cout << "========================================\n";

  for (auto &proc : processes) {
    start_process(proc);
  }

  auto last_health_check = std::chrono::steady_clock::now();

  while (running) {
    std::this_thread::sleep_for(std::chrono::milliseconds(500));

    // Periodic Health Check for Backend
    auto now = std::chrono::steady_clock::now();
    if (std::chrono::duration_cast<std::chrono::milliseconds>(now -
                                                              last_health_check)
            .count() > global_config.health_check_interval_ms) {
      last_health_check = now;
      if (!check_health(global_config.port)) {
        std::cout << "[Orchestrator] Backend health check failed! Attempting "
                     "recovery...\n";
        for (auto &proc : processes) {
          if (proc.name == "Backend" && proc.pid > 0) {
            kill(proc.pid, SIGTERM);
            // Loop will handle restart in next iteration
          }
        }
      }
    }

    for (auto &proc : processes) {
      if (proc.pid == 0) {
        // Check if we need to restart
        if (proc.restart_on_fail && running &&
            proc.restart_attempts < proc.max_restarts) {

          // Reset attempts if it was running for a while (> 30s)
          auto uptime = std::chrono::duration_cast<std::chrono::seconds>(
                            now - proc.last_start_time)
                            .count();
          if (uptime > 30) {
            proc.restart_attempts = 0;
            proc.current_backoff_ms = 0;
          }

          // Exponential Backoff
          if (proc.current_backoff_ms == 0)
            proc.current_backoff_ms = 1000;
          else
            proc.current_backoff_ms =
                std::min(proc.current_backoff_ms * 2, 16000);

          std::cout << "[Orchestrator] " << proc.name
                    << " is down. Restarting in " << proc.current_backoff_ms
                    << "ms...\n";
          std::this_thread::sleep_for(
              std::chrono::milliseconds(proc.current_backoff_ms));

          proc.restart_attempts++;
          start_process(proc);
        } else if (proc.is_master && proc.pid == 0) {
          // Master (Frontend) exited, shutdown everything
          std::cout
              << "[Orchestrator] Master interface closed. Shutting down...\n";
          running = false;
          break;
        }
      } else {
        // Check if PID is still alive (non-blocking)
        if (kill(proc.pid, 0) == -1) {
          proc.pid = 0; // Mark as dead
        }
      }
    }
  }

  stop_all_processes();
  std::cout << "[Orchestrator] Cleanup complete. System offline.\n";
  return 0;
}
