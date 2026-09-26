#pragma once

#include <array>
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
  std::array<float, 3> camera_position = {1, 2, -3};
  std::array<float, 3> camera_look_at = {1, 2, -2};

  bool water_enabled = true;
  std::string water_scene = "drop";
  unsigned water_resolution = 32;
  // Never run the simulation ahead of the wall clock. When it can't keep up, the
  // water plays in slow motion either way.
  bool water_realtime = true;
  // World position of the middle of the tank's floor, and world units per meter.
  std::array<float, 3> water_position = {-0.5f, -1.0f, 5.0f};
  float water_scale = 10;
  // Beer–Lambert absorption per meter of water for red, green, blue. Default:
  // measured values for pure water (Pope & Fry 1997, at 650/550/450 nm).
  std::array<float, 3> water_absorption = {0.34f, 0.057f, 0.0092f};
  float water_ior = 1.33f;
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

inline bool parse_value(const std::string& raw, bool& out) {
  if (raw == "true" || raw == "false") {
    out = raw == "true";
    return true;
  }
  return false;
}

// "[a, b, c]": exactly three numbers.
inline bool parse_value(const std::string& raw, std::array<float, 3>& out) {
  if (raw.size() < 2 || raw.front() != '[' || raw.back() != ']') {
    return false;
  }
  std::array<float, 3> values;
  size_t start = 1;
  for (size_t n = 0; n < 3; ++n) {
    size_t end = raw.find(n < 2 ? ',' : ']', start);
    if (end == std::string::npos || !parse_value(trim(raw.substr(start, end - start)), values[n])) {
      return false;
    }
    start = end + 1;
  }
  if (start != raw.size()) {
    return false;
  }
  out = values;
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
  using Field = std::variant<unsigned*, int*, float*, bool*, std::array<float, 3>*, std::string*>;
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
      {"camera.position", &cfg.camera_position},
      {"camera.look_at", &cfg.camera_look_at},
      {"water.enabled", &cfg.water_enabled},
      {"water.scene", &cfg.water_scene},
      {"water.resolution", &cfg.water_resolution},
      {"water.realtime", &cfg.water_realtime},
      {"water.position", &cfg.water_position},
      {"water.scale", &cfg.water_scale},
      {"water.absorption", &cfg.water_absorption},
      {"water.ior", &cfg.water_ior},
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
