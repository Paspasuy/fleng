#include <SFML/Graphics.hpp>
#include "bits/stdc++.h"

#include "math.hpp"
#include "camera.hpp"
#include "objects/objects.hpp"

// #include <GL/glew.h>

signed main() {
  // sf::Glsl::Mat4 *mtx;// = new sf::Glsl::Mat4[2];
  sf::RenderWindow window(sf::VideoMode(VIEWPORT_WIDTH, VIEWPORT_HEIGHT),
                          APP_TITLE);  //, sf::Style::Fullscreen);
  window.setFramerateLimit(FRAMERATE_LIMIT);
  sf::RectangleShape rect(sf::Vector2f(VIEWPORT_WIDTH, VIEWPORT_HEIGHT));
  // rect.setPosition(100, 100);
  rect.setFillColor(sf::Color::Green);
  sf::Shader shader;
  const std::string shader_path = SHADERS_DIR + std::string("fleng.frag");

  if (!shader.loadFromFile(shader_path, sf::Shader::Fragment)) {
    std::cerr << "YOU SUCKED(\n";
    return -1;
  }
  sf::RenderTexture renderTexture;
  renderTexture.create(VIEWPORT_WIDTH, VIEWPORT_HEIGHT);
  renderTexture.clear();
  renderTexture.draw(rect);
  renderTexture.display();
  sf::Sprite sprite(renderTexture.getTexture());
  int t = 0;

  std::vector<RenderObject*> obj;
  // Shader uses that first object is floor
  obj.push_back(new Plane(vec3(0, -1, 0), vec4(0.5, 0.3, 0.2, 0.4), vec3(0, 1, 0)));

  obj.push_back(new Sphere(vec3(2, 2.2, 0), vec4(1.0, 0.6, 0.8, 1.), 0.7));
  obj.push_back(new Sphere(vec3(0, 1.7, 1), vec4(0.5, 0.7, 1., 1.), 0.7));
  obj.push_back(new Cuboid(vec3(2, 3.5, 2), vec4(0.4, 1.0, 0.6, 1.), vec3(0.5, 3, 1)));
  obj.push_back(new Cuboid(vec3(5, 5, 5), vec4(0.8, 0.9, 0.95, 1.), 1.8));
  obj.push_back(new Cuboid(vec3(9, 5, 5), vec4(0.8, 0.9, 0.95, 1.), 1.8));
  // obj.push_back(new Sphere(vec3(1, 2.5, 1), vec4(1.0, 1.0, 1.0, 0.9), 0.3));

  // Light sources
  obj.push_back(new Sphere(vec3(1, 2.5, 1), vec4(0.0, 1.0, 1.0, -1.0), 0.3));
  obj.push_back(new Cuboid(vec3(-6, 5, 5.), vec4(0.95, 0.55, 0.31, -1.), vec3(0.1, 6, 5)));

  // Fractals
  // obj.push_back(new FractalCube(vec4(0.0, 1.0, 0.5, 1.)));
  // obj.push_back(new SerpinskyTetrahedron(vec4(1.0, 0.7, 0.0, 1.)));
  obj.push_back(new MandelBulb(vec3(-0.7, 2, 3.5), vec4(0.9, 0.2, 0.2, 1.)));
  Camera cam;

  sf::Clock cl;

  int MARCH = INITIAL_MARCH_ITERATIONS;

  int v = 1;
  bool paused = 0;
  while (window.isOpen()) {
    sf::Event event;
    while (window.pollEvent(event)) {
      if (event.type == sf::Event::Closed)
        window.close();
      if (event.type == sf::Event::KeyPressed) {
        if (event.key.code == sf::Keyboard::Hyphen)
          cam.mt_sz *= 1.1;
        if (event.key.code == sf::Keyboard::Equal)
          cam.mt_sz /= 1.1;
        if (event.key.code == sf::Keyboard::Space)
          paused ^= 1;
        if (event.key.code == sf::Keyboard::Num3)
          MARCH -= 20;
        if (event.key.code == sf::Keyboard::Num4)
          MARCH += 20;
        if (event.key.code == sf::Keyboard::Num5)
          cam.speed /= 10;
        if (event.key.code == sf::Keyboard::Num6)
          cam.speed *= 10;
        if (event.key.code == sf::Keyboard::Num7) {
        }
      }
    }
    if (sf::Keyboard::isKeyPressed(sf::Keyboard::W))
      cam.forward();
    if (sf::Keyboard::isKeyPressed(sf::Keyboard::S))
      cam.backward();
    if (sf::Keyboard::isKeyPressed(sf::Keyboard::D))
      cam.right();
    if (sf::Keyboard::isKeyPressed(sf::Keyboard::A))
      cam.left();
    if (sf::Keyboard::isKeyPressed(sf::Keyboard::Right))
      cam.rot_xz(true);
    if (sf::Keyboard::isKeyPressed(sf::Keyboard::Left))
      cam.rot_xz(false);
    if (sf::Keyboard::isKeyPressed(sf::Keyboard::Up))
      cam.rot_yz(true);
    if (sf::Keyboard::isKeyPressed(sf::Keyboard::Down))
      cam.rot_yz(false);
    if (sf::Keyboard::isKeyPressed(sf::Keyboard::Num2))
      cam.rot_xy(true);
    if (sf::Keyboard::isKeyPressed(sf::Keyboard::Num1))
      cam.rot_xy(false);
    /*        if (!paused) {
                (sph[2].pos.y += 0.01 * v);
                if (sph[2].pos.y > 1.0  || sph[2].pos.y < 0.01) v = -v;
            }*/

    std::vector<sf::Glsl::Mat4> mtx;
    for (RenderObject* object : obj) {
      mtx.emplace_back(sf::Glsl::Mat4(object->exportData().data()));
    }
    sf::Time elapsed = cl.getElapsedTime();
    float time = elapsed.asSeconds();
    // std::cerr << CLOCKS_PER_SEC << '\n';
    // float time = float(clock())/CLOCKS_PER_SEC;
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
    shader.setUniform("obj_cnt", int(mtx.size()));
    shader.setUniformArray("objects", mtx.data(), mtx.size());
    // GLfloat ut = glGetUniformLocation(ProgramObject, "u_time");
    // if (ut != -1)
    // glUniform1f(ut, clock() / CLOCKS_PER_SEC);
    window.clear(sf::Color::Black);
    window.draw(sprite, &shader);
    window.display();
  }
  for (RenderObject* object : obj) {
    delete object;
  }
  return 0;
}
