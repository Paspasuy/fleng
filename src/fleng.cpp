#include <SFML/Graphics.hpp>
#include "bits/stdc++.h"

#include "math.hpp"
#include "camera.hpp"
#include "utils/constants.hpp"

// #include <GL/glew.h>

struct Sph {
    vec3 pos;
    vec4 color;
    vec4 prop;
    Sph() {}
    Sph(vec3 _pos, vec4 _color, vec4 _prop) {pos = _pos; color = _color; prop = _prop;}
};

struct Pln {
    vec3 pos;
    vec4 color;
    vec3 norm;
    Pln() {}
    Pln(vec3 _pos, vec4 _color, vec3 _norm) {pos = _pos; color = _color; norm = _norm;}
};


signed main()
{
    // sf::Glsl::Mat4 *mtx;// = new sf::Glsl::Mat4[2];
    sf::RenderWindow window(sf::VideoMode(VIEWPORT_WIDTH, VIEWPORT_HEIGHT), APP_TITLE);//, sf::Style::Fullscreen);
    window.setFramerateLimit(FRAMERATE_LIMIT);
    sf::RectangleShape rect(sf::Vector2f(VIEWPORT_WIDTH, VIEWPORT_HEIGHT));
    // rect.setPosition(100, 100);
    rect.setFillColor(sf::Color::Green);
    sf::Shader shader;
    const std::string shader_path = SHADERS_DIR + std::string("fleng.frag");
    
    if (!shader.loadFromFile(shader_path, sf::Shader::Fragment))
    {
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
    std::vector<Sph> sph;
    std::vector<Pln> pln;
    sph.emplace_back(Sph(vec3(0, 0, 0), vec4(1.0, 1.0, 1., 1.), vec4(0.2, 0., 0., 0.)));
    // sph.emplace_back(Sph(vec3(1, 0, 0), vec4(1.0, 0.0, 0., 1.), vec4(0.2, 0., 0., 0.)));
    // sph.emplace_back(Sph(vec3(0, 1, 0), vec4(0.0, 1.0, 0., 1.), vec4(0.2, 0., 0., 0.)));
    // sph.emplace_back(Sph(vec3(0, 0, 1), vec4(0.0, 0.0, 1., 1.), vec4(0.2, 0., 0., 0.)));
    pln.emplace_back(Pln(vec3(0, -1, 0), vec4(1.0, 0.3, 1., 1.), vec3(0, 1, 0)));
    Camera cam;
    // sf::Clock cl;

    int MARCH = INITIAL_MARCH_ITERATIONS;

    int v = 1;
    bool paused = 0;
    while (window.isOpen())
    {
        sf::Event event;
        while (window.pollEvent(event)) 
        {
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
        for (size_t i = 0; i < sph.size(); ++i) {
            float array[16] =
            {
                sph[i].pos.x, sph[i].pos.y, sph[i].pos.z, 0,
                sph[i].color.x, sph[i].color.y, sph[i].color.z, sph[i].color.w,
                0, sph[i].prop.x, 0, 0,
                0, 0, 0, 0
            };
            mtx.emplace_back(sf::Glsl::Mat4(array));
        }
        for (size_t i = 0; i < pln.size(); ++i) {
            float array[16] =
            {
                pln[i].pos.x, pln[i].pos.y, pln[i].pos.z, 0,
                pln[i].color.x, pln[i].color.y, pln[i].color.z, pln[i].color.w,
                1, pln[i].norm.x, pln[i].norm.y, pln[i].norm.z,
                0, 0, 0, 0
            };
            mtx.emplace_back(sf::Glsl::Mat4(array));
        }
        // Fractal
        {
            float array[16] =
            {
                0, 0, 0, 0,
                0.0, 1.0, 0.5, 1.0,
                102, 2.0, 50, 0.5,
                0, 0, 0, 0
            };
            mtx.emplace_back(sf::Glsl::Mat4(array));
        }
        // sf::Time elapsed = cl.restart();
        // std::cerr << elapsed.asSeconds() * 60 << '\n';
        // std::cerr << CLOCKS_PER_SEC << '\n';
        // float alpha = float(clock())/CLOCKS_PER_SEC*1000;
        // alpha -= int(alpha / M_PI / 2) * M_PI * 2;
        // shader.setUniform("scale", scale);
        std::cout << cam.campos.x << ' ' << cam.campos.y << ' ' << cam.campos.z << ' ' << MARCH << '\n';// << ' ' << cam.xz_ang << ' ' << cam.yz_ang << '\n'; 
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
    return 0;
}
