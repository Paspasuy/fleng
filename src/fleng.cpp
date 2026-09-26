#include <SFML/Graphics.hpp>
#include <algorithm>
#include <array>
#include <iostream>
#include <memory>
#include <numeric>
#include <optional>
#include <string>
#include <vector>

#include "utils/config.hpp"
#include "utils/utils.hpp"
#include "utils/MP4Player.cpp"
#include "math.hpp"
#include "camera.hpp"
#include <cassert>
#include "objects/objects.hpp"
#include "water.hpp"

// #include <GL/glew.h>

// Saves what's on screen (the accumulated image) as PNG.
static bool saveScreenshot(const sf::RenderTexture& image, const std::string& path) {
  const bool ok = image.getTexture().copyToImage().saveToFile(path);
  std::cout << (ok ? "saved " : "could not save ") << path << std::endl;
  return ok;
}

signed main(int argc, char** argv) {
  // fleng [config.toml] [--screenshot PATH SECONDS]
  std::string config_path = "fleng.toml";
  std::string screenshot_path;
  float screenshot_after = 0;
  for (int i = 1; i < argc; ++i) {
    const std::string arg = argv[i];
    if (arg == "--screenshot" && i + 2 < argc) {
      screenshot_path = argv[i + 1];
      screenshot_after = std::stof(argv[i + 2]);
      i += 2;
    } else {
      config_path = arg;
    }
  }
  if (!load_config(config_path, config)) {
    return -1;
  }
  const sf::Vector2u viewport(config.window_width, config.window_height);

  // sf::Glsl::Mat4 *mtx;// = new sf::Glsl::Mat4[2];
  sf::RenderWindow window(sf::VideoMode(viewport),
                          sf::String::fromUtf8(config.window_title.begin(), config.window_title.end()));  //, sf::Style::Fullscreen);
  window.setFramerateLimit(config.window_framerate_limit);
  sf::RectangleShape rect{sf::Vector2f(viewport)};
  // rect.setPosition(100, 100);
  rect.setFillColor(sf::Color::Green);
  window.setMouseCursorVisible(false);
  sf::Shader shader;
  const std::string shader_path = config.paths_shaders + "fleng.frag";

  if (!shader.loadFromFile(shader_path, sf::Shader::Type::Fragment)) {
    std::cerr << "Failed to load shader\n";
    return -1;
  }

  sf::Shader accumulateShader;
  if (!accumulateShader.loadFromFile(config.paths_shaders + "accumulate.frag", sf::Shader::Type::Fragment)) {
    std::cerr << "Failed to load shader\n";
    return -1;
  }

  sf::Texture tI2(config.paths_image);
  tI2.setSmooth(true);

  MP4Player player;
  if (!player.initialize(config.paths_video)) {
      std::cerr << "Failed to initialize video player" << std::endl;
      // return -1;
  }
  std::unique_ptr<sf::Texture> player_texture;

  sf::RenderTexture currentRT;
  sf::RenderTexture accumRT;
//  sf::RenderTexture prev;

  assert(currentRT.resize(viewport));
  assert(accumRT.resize(viewport));
//  assert(prev.resize(viewport));

  sf::Sprite current(currentRT.getTexture());
  sf::Sprite prev(accumRT.getTexture());

  // Simulated water (docs/water-plan.md): runs on its own thread; the shader
  // reads its surface from a 3D texture on a fixed texture unit.
  Water water;
  shader.setUniform("water_on", 0);
  if (config.water_enabled) {
    water.start();
    sf::Shader::bind(&shader);
    glUniform1i(glGetUniformLocation(shader.getNativeHandle(), "water_phi"), Water::texture_unit);
    sf::Shader::bind(nullptr);
  }
  //fullscreen.setTexture(currentRT.getTexture());


  std::vector<RenderObject*> obj;
  // Shader uses that first object is floor
  //obj.push_back(new Plane(vec3(0, -1, 0), vec4(1., 0.7, 0.50, 0.90), vec3(0, 1, 0.)));
  obj.push_back(new Plane(vec3(0, -1, 0), vec4(0.4, 0.3, 0.20, 0.99), vec3(0, 1, 0.)));
  //  obj.push_back(new Plane(vec3(0, -1, 0), vec4(0.1, 0.1, 0.10, 0.5), vec3(0, 1, 0.4)));

  obj.push_back(new Sphere(vec3(2, 2.2, 0), vec4(1.0, 0.6, 0.8, 1.), 0.7));
//  obj.push_back(new Sphere(vec3(0, 1.7, 1), vec4(0.2, 0.2, 0.2, 0.0), 0.7));
  obj.push_back(new Cuboid(vec3(2, 3.5, 2), vec4(0.4, 1.0, 0.6, 1.), vec3(0.5, 3, 1)));
  obj.push_back(new Cuboid(vec3(5, 5, 5), vec4(0.7, 0.8, 0.95, 1.), 1.8));
  obj.push_back(new Cuboid(vec3(9, 5, 5), vec4(0.7, 0.8, 0.95, 1.), 1.8));


  obj.push_back(new Sphere(vec3(-5, 2.2, -1), vec4(1.0, 1.0, 1.0, -5.05), 0.7, true));
  obj.push_back(new Sphere(vec3(-1, 2.2, -1), vec4(1.0, 1.0, 1.0, -5.05), 0.7, true));
  obj.push_back(new Sphere(vec3(-3, 1.6, 1), vec4(0.4, 0.9, 0.9, -0.05), 0.7, true));
  // obj.push_back(new Sphere(vec3(1, 2.5, 1), vec4(1.0, 1.0, 1.0, 0.9), 0.3));

  // For perftest in future
/*
  for (int i = 0; i < 100; ++i) {
    obj.push_back(new Sphere(vec3(2 * i, 2.2, 0), vec4(1.0, 1.0, 1.0, 0.5), 0.7));
  }
*/
  // Light sources
  obj.push_back(new Sphere(vec3(1, 2.5, 1), vec4(0.0, 1.0, 1.0, -1.0), 0.3));
  obj.push_back(new Cuboid(vec3(-6, 5, 5.), vec4(0.95, 0.75, 0.31, -1.), vec3(0.1, 6, 5)));

  // Textured
  obj.push_back(new Cuboid(vec3(4, 3, -12.), vec4(1.0, 0.0, 0.0, -1.), vec3(5, 3, 0.1)));
  obj.push_back(new Cuboid(vec3(-8, 3, -12.), vec4(1.0, 0.0, 0.0, -1.), vec3(5, 3, 0.1)));

  // Fractals
  //obj.push_back(new FractalCube(vec4(0.0, 1.0, 0.5, 1.)));
  //obj.push_back(new SerpinskyTetrahedron(vec4(1.0, 0.7, 0.0, 1.)));
  //obj.push_back(new MandelBulb(vec3(-0.7, 2, 3.5), vec4(0.9, 0.2, 0.2, 1.)));

  Camera cam;

  sf::Clock cl;
  sf::Clock fps_clock;
  float last_time = 0;

  int MARCH = config.render_march_iterations;

  int frames = 0;
  float fps = 0;
  uint32_t stale = 0;

  bool blur = false;
  bool paused = 0;
  while (window.isOpen()) {

    if (blur) ++stale;
    ++frames;
    while (const std::optional event = window.pollEvent()) {
      if (event->is<sf::Event::Closed>())
        window.close();
      if (const auto* keyPressed = event->getIf<sf::Event::KeyPressed>()) {
        stale = 0;
        if (keyPressed->scancode == sf::Keyboard::Scancode::Hyphen)
          cam.mt_sz *= 1.1;
        if (keyPressed->scancode == sf::Keyboard::Scancode::Equal)
          cam.mt_sz /= 1.1;
        if (keyPressed->scancode == sf::Keyboard::Scancode::Space)
          paused ^= 1;
        if (keyPressed->scancode == sf::Keyboard::Scancode::Num3)
          MARCH -= 20;
        if (keyPressed->scancode == sf::Keyboard::Scancode::Num4)
          MARCH += 20;
        if (keyPressed->scancode == sf::Keyboard::Scancode::Num5)
          cam.speed /= 10;
        if (keyPressed->scancode == sf::Keyboard::Scancode::Num6)
          cam.speed *= 10;
        if (keyPressed->scancode == sf::Keyboard::Scancode::Num7) {
        }
        if (keyPressed->scancode == sf::Keyboard::Scancode::F12) {
          static int shot = 0;
          saveScreenshot(accumRT, "screenshot_" + std::to_string(++shot) + ".png");
        }
        if (keyPressed->scancode == sf::Keyboard::Scancode::R)
          water.reset();
        if (keyPressed->scancode == sf::Keyboard::Scancode::T)
          water.togglePause();
        if (keyPressed->scancode == sf::Keyboard::Scancode::P) {
          blur ^= 1;
        }
      }
    }
    if (sf::Keyboard::isKeyPressed(sf::Keyboard::Key::W)) {
      cam.forward();
      stale = 0;
    } if (sf::Keyboard::isKeyPressed(sf::Keyboard::Key::S)) {
      cam.backward();
      stale = 0;
    } if (sf::Keyboard::isKeyPressed(sf::Keyboard::Key::D)) {
      cam.right();
      stale = 0;
    } if (sf::Keyboard::isKeyPressed(sf::Keyboard::Key::A)) {
      cam.left();
      stale = 0;
    } if (sf::Keyboard::isKeyPressed(sf::Keyboard::Key::Right)) {
      cam.rot_xz(true);
      stale = 0;
    } if (sf::Keyboard::isKeyPressed(sf::Keyboard::Key::Left)) {
      cam.rot_xz(false);
      stale = 0;
    } if (sf::Keyboard::isKeyPressed(sf::Keyboard::Key::Up)) {
      cam.rot_yz(true);
      stale = 0;
    } if (sf::Keyboard::isKeyPressed(sf::Keyboard::Key::Down)) {
      cam.rot_yz(false);
      stale = 0;
    } if (sf::Keyboard::isKeyPressed(sf::Keyboard::Key::Num2)) {
      cam.rot_xy(true);
      stale = 0;
    } if (sf::Keyboard::isKeyPressed(sf::Keyboard::Key::Num1)) {
      cam.rot_xy(false);
      stale = 0;
    } /*        if (!paused) {
                (sph[2].pos.y += 0.01 * v);
                if (sph[2].pos.y > 1.0  || sph[2].pos.y < 0.01) v = -v;
            }*/

    player_texture = player.getNextFrame();

    std::vector<sf::Glsl::Mat4> shader_input_objects;
    for (RenderObject* object : obj) {
      shader_input_objects.emplace_back(sf::Glsl::Mat4(object->exportData().data()));
    }
    std::vector<sf::Glsl::Mat4> important_indices;
    for (size_t idx = 0; idx < obj.size(); ++idx) {
      important_indices.emplace_back(sf::Glsl::Mat4(get_nearest(obj, idx).data()));
    }
    sf::Time elapsed = cl.getElapsedTime();
    float time = elapsed.asSeconds();
    // std::cerr << CLOCKS_PER_SEC << '\n';
    // float time = float(clock())/CLOCKS_PER_SEC;
//    obj[6]->pos.y = 2.2 + sin(float(time)) * 2;
//    static_cast<Sphere*>(obj[6])->color.x = (sin(float(time)) - 1) / 2;
//    static_cast<Sphere*>(obj[6])->color.y = (sin(float(time)) - 1) / 2;
//    static_cast<Sphere*>(obj[6])->color.w = (sin(float(time * 2)) - 1) / 2 * 0.05 * 100;
    shader.setUniform("time", time);
    // alpha -= int(alpha / M_PI / 2) * M_PI * 2;
    // shader.setUniform("scale", scale);
    //    std::cout << cam.campos.x << ' ' << cam.campos.y << ' ' << cam.campos.z << ' ' << MARCH << ' ' << time
    //              << '\n';  // << ' ' << cam.xz_ang << ' ' << cam.yz_ang << '\n';
    shader.setUniform("MARCH", MARCH);
    shader.setUniform("mt_sz", cam.mt_sz);
    shader.setUniform("cam_pos", cam.campos.to_glsl());
    shader.setUniform("cam_dir", cam.camor.get_z().to_glsl());
    shader.setUniform("xaxis", cam.camor.get_x().to_glsl());
    shader.setUniform("obj_cnt", int(shader_input_objects.size()));
    shader.setUniformArray("objects", shader_input_objects.data(), shader_input_objects.size());


//    shader.setUniformArray("obj_indices", important_indices.data(), important_indices.size());

    shader.setUniform("image2", tI2);
    shader.setUniform("image2_o", 10);

//    shader.setUniform("image2", *player_texture);
//    shader.setUniform("image2_o", 11);
    if (player_texture) shader.setUniform("video", *player_texture);
    shader.setUniform("video_o", 11);
     // GLfloat ut = glGetUniformLocation(ProgramObject, "u_time");
    // if (ut != -1)
    // glUniform1f(ut, clock() / CLOCKS_PER_SEC);
//    window.clear(sf::Color::Black);

    if (config.water_enabled) {
      // Texture uploads and bindings belong to the context that draws the shader.
      (void)currentRT.setActive(true);
      if (water.upload()) {
        water.setUniforms(shader);
        stale = 0;  // the water moved: restart image accumulation
      }
      if (water.ready()) water.bind();
    }

    currentRT.clear(sf::Color::Black);
    currentRT.draw(current, &shader);
    currentRT.display();


    accumulateShader.setUniform("currentFrame", currentRT.getTexture());
    accumulateShader.setUniform("previousAccum", accumRT.getTexture());
    accumulateShader.setUniform("invN", 1.f / float(stale + 1));
    accumulateShader.setUniform("prevFactor", float(stale) / float(stale + 1));

    accumRT.draw(current, &accumulateShader);
    accumRT.display();

    window.draw(sf::Sprite(accumRT.getTexture()));
    if (fps_clock.getElapsedTime().asSeconds() > 0.5) {
      float currentTime = fps_clock.getElapsedTime().asSeconds();
      float fps = frames / currentTime;
      std::cout << "fps: " << fps;
      if (config.water_enabled) std::cout << "  |  " << water.status();
      std::cout << std::endl;
      frames = 0;
      fps_clock.restart();
    }
    window.display();

    if (!screenshot_path.empty() && cl.getElapsedTime().asSeconds() >= screenshot_after) {
      saveScreenshot(accumRT, screenshot_path);
      window.close();
    }
  }
  for (RenderObject* object : obj) {
    delete object;
  }
  return 0;
}
