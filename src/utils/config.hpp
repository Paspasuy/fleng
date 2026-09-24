#pragma once

#include <cctype>
#include <cerrno>
#include <climits>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <map>
#include <string>
#include <variant>

// Runtime settings. Loaded from a flat TOML file (fleng.toml); anything the file leaves out keeps the default below.
struct Config {
  unsigned window_width = 1800;
  unsigned window_height = 1800;
  unsigned window_framerate_limit = 60;
  std::string window_title = "fleng";

  std::string paths_shaders = "shaders/";
  std::string paths_image = "assets/image.jpg";
  std::string paths_video = "assets/video.mp4";

  int render_march_iterations = 200;

  float camera_matrix_size = 0.001;
  float camera_speed = 0.2;
  float camera_rotation_angle = 0.05;
};

inline Config config;

namespace config_detail {

inline std::string trim(const std::string& s) {
  size_t b = s.find_first_not_of(" \t\r");
  if (b == std::string::npos) {
    return "";
  }
  size_t e = s.find_last_not_of(" \t\r");
  return s.substr(b, e - b + 1);
}

// Cuts a trailing "# comment", ignoring '#' inside a quoted string.
inline std::string strip_comment(const std::string& s) {
  bool quoted = false;
  for (size_t i = 0; i < s.size(); ++i) {
    if (s[i] == '"') {
      quoted = !quoted;
    } else if (s[i] == '#' && !quoted) {
      return s.substr(0, i);
    }
  }
  return s;
}

inline bool parse_value(const std::string& raw, unsigned& out) {
  if (raw.empty() || !std::isdigit(static_cast<unsigned char>(raw[0]))) {
    return false;
  }
  char* end = nullptr;
  errno = 0;
  unsigned long v = std::strtoul(raw.c_str(), &end, 10);
  if (*end != '\0' || errno == ERANGE || v > UINT_MAX) {
    return false;
  }
  out = static_cast<unsigned>(v);
  return true;
}

inline bool parse_value(const std::string& raw, int& out) {
  char* end = nullptr;
  errno = 0;
  long v = std::strtol(raw.c_str(), &end, 10);
  if (raw.empty() || *end != '\0' || errno == ERANGE || v < INT_MIN || v > INT_MAX) {
    return false;
  }
  out = static_cast<int>(v);
  return true;
}

inline bool parse_value(const std::string& raw, float& out) {
  char* end = nullptr;
  errno = 0;
  float v = std::strtof(raw.c_str(), &end);
  if (raw.empty() || *end != '\0' || errno == ERANGE) {
    return false;
  }
  out = v;
  return true;
}

inline bool parse_value(const std::string& raw, std::string& out) {
  if (raw.size() < 2 || raw.front() != '"' || raw.back() != '"') {
    return false;
  }
  out = raw.substr(1, raw.size() - 2);
  return true;
}

}  // namespace config_detail

// Returns false (after printing why) if the file exists but is malformed. A missing file just means defaults.
inline bool load_config(const std::string& path, Config& cfg) {
  using namespace config_detail;
  using Field = std::variant<unsigned*, int*, float*, std::string*>;
  const std::map<std::string, Field> fields = {
      {"window.width", &cfg.window_width},
      {"window.height", &cfg.window_height},
      {"window.framerate_limit", &cfg.window_framerate_limit},
      {"window.title", &cfg.window_title},
      {"paths.shaders", &cfg.paths_shaders},
      {"paths.image", &cfg.paths_image},
      {"paths.video", &cfg.paths_video},
      {"render.march_iterations", &cfg.render_march_iterations},
      {"camera.matrix_size", &cfg.camera_matrix_size},
      {"camera.speed", &cfg.camera_speed},
      {"camera.rotation_angle", &cfg.camera_rotation_angle},
  };

  std::ifstream in(path);
  if (!in) {
    std::cerr << "Config " << path << " not found, using defaults" << std::endl;
    return true;
  }

  bool ok = true;
  std::string section;
  std::string line;
  for (int line_no = 1; std::getline(in, line); ++line_no) {
    auto fail = [&](const std::string& msg) {
      std::cerr << path << ":" << line_no << ": " << msg << std::endl;
      ok = false;
    };
    line = trim(strip_comment(line));
    if (line.empty()) {
      continue;
    }
    if (line.front() == '[') {
      if (line.back() != ']') {
        fail("unterminated section header");
        continue;
      }
      section = trim(line.substr(1, line.size() - 2));
      continue;
    }
    size_t eq = line.find('=');
    if (eq == std::string::npos) {
      fail("expected 'key = value'");
      continue;
    }
    std::string key = trim(line.substr(0, eq));
    std::string value = trim(line.substr(eq + 1));
    std::string full_key = section.empty() ? key : section + "." + key;

    auto it = fields.find(full_key);
    if (it == fields.end()) {
      std::cerr << path << ":" << line_no << ": unknown key '" << full_key << "', ignored" << std::endl;
      continue;
    }
    bool parsed = std::visit([&](auto* field) { return parse_value(value, *field); }, it->second);
    if (!parsed) {
      fail("bad value for '" + full_key + "': " + value);
    }
  }
  return ok;
}
