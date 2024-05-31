#include <SFML/Graphics.hpp>
#include "bits/stdc++.h"
// #include <GL/glew.h>
typedef long double ld;

using pld = std::pair<ld,ld>;
using pii = std::pair<int,int>;

// const int H = 50, W = 50;
const int H = 800, W = 800;
// const int H = 1920, W = 1920;

struct vec2 {
    float x, y;
    vec2(float _x, float _y) {x = _x; y = _y;}
    vec2() {}
};

vec2 rot(vec2 v, float alpha) {
    vec2 res;
    res.x = v.x * cos(alpha) - v.y * sin(alpha);
    res.y = v.y * cos(alpha) + v.x * sin(alpha);
    return res;
}

struct vec3 {
    float x, y, z;
    vec3(float _x, float _y, float _z) {x = _x; y = _y; z = _z;}
    vec3() {}
    vec3 operator+(vec3 p) {return vec3(x+p.x, y+p.y, z+p.z);}
    void operator+=(vec3 p) {x+=p.x; y+=p.y; z+=p.z;}
    void operator-=(vec3 p) {x-=p.x; y-=p.y; z-=p.z;}
    vec3 operator-(vec3 p) {return vec3(x-p.x, y-p.y, z-p.z);}
    vec3 operator*(float p) {return vec3(x * p, y * p, z * p);}
    float operator*(vec3 p) {return x*p.x + y*p.y + z*p.z;}
    float sz() {return sqrt(x * x + y * y + z * z);}
    vec3 norm() {float l = sz(); return vec3(x / l, y / l, z / l);};
    void rot_xz(float alpha) {vec2 susik = rot(vec2(x, z), alpha); x = susik.x; z = susik.y;}
    void rot_yz(float alpha) {vec2 susik = rot(vec2(y, z), alpha); y = susik.x; z = susik.y;}
    void rot_xy(float alpha) {vec2 susik = rot(vec2(x, y), alpha); x = susik.x; y = susik.y;}
    sf::Glsl::Vec3 to_glsl() {
        return sf::Glsl::Vec3(x, y, z);
    }
};

struct vec4 {
    float x, y, z, w;
    vec4(float _x, float _y, float _z, float _w) {x = _x; y = _y; z = _z; w = _w;}
    vec4() {}
};

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

struct M3x3 {
    float a[3][3];
    M3x3() {a[0][0] = a[1][1] = a[2][2] = 1; a[0][1] = a[1][0] = a[2][0] = a[0][2] = a[1][2] = a[2][1] = 0;}
    vec3 get_x() {return vec3(a[0][0], a[1][0], a[2][0]);}
    vec3 get_y() {return vec3(a[0][1], a[1][1], a[2][1]);}
    vec3 get_z() {return vec3(a[0][2], a[1][2], a[2][2]);}
};

M3x3 mul(M3x3 m1, M3x3 m2) {
    M3x3 ans;
    for (int i = 0; i < 3; ++i) {
        for (int j = 0; j < 3; ++j) {
            ans.a[i][j] = 0;
            for (int k = 0; k < 3; ++k) {
                ans.a[i][j] += m1.a[i][k] * m2.a[k][j];
            }
        }
    }
    return ans;
}

vec3 mul(M3x3 &m, vec3 &v) {
    vec3 ans;
    ans.x = m.a[0][0] * v.x + m.a[0][1] * v.y + m.a[0][2] * v.z;
    ans.y = m.a[1][0] * v.x + m.a[1][1] * v.y + m.a[1][2] * v.z;
    ans.z = m.a[2][0] * v.x + m.a[2][1] * v.y + m.a[2][2] * v.z;
    return ans;
}

M3x3 get_rot(int a1, int a2, float phi) {
    M3x3 ans;
    ans.a[a1][a1] = cos(phi);
    ans.a[a1][a2] = sin(phi);
    ans.a[a2][a1] = -sin(phi);
    ans.a[a2][a2] = cos(phi);
    return ans;//.norm();
}

struct Camera {
    float mt_sz = 0.001;
    float speed = 0.2;
    const float rot_ang = 0.05;
    vec3 campos;
    M3x3 camor;
    // Camera() {campos = vec3(1.0, 1.0, 0.0); xaxis = vec3(1, 0, 0).norm(); camdir = vec3(0, 0, 3).norm();}
    Camera() { campos = vec3(1.0, 2.0, -3.0); camor = M3x3(); }
    void forward() { campos += camor.get_z() * speed; }
    void backward() { campos -= camor.get_z() * speed; }
    void right() { campos += camor.get_x() * speed; }
    void left() { campos -= camor.get_x() * speed; }
    void up() { campos += camor.get_y() * speed; }
    void down() { campos -= camor.get_y() * speed; }
    // rot_xz/yaw/рысканье
    void rot_xz(bool positive) {
        float phi = (positive? rot_ang: -rot_ang);
        camor = mul(camor, get_rot(0, 2, phi));
    }
    // rot_yz/pitch/тангаж
    void rot_yz(bool positive) {
        float phi = (positive? rot_ang: -rot_ang);
        camor = mul(camor, get_rot(1, 2, phi));
    }
    // rot_xy/roll/крен
    void rot_xy(bool positive) {
        float phi = (positive? rot_ang: -rot_ang);
        camor = mul(camor, get_rot(0, 1, phi));
    }
};
#include <unistd.h>
signed main()
{
    // sf::Glsl::Mat4 *mtx;// = new sf::Glsl::Mat4[2];
    sf::RenderWindow window(sf::VideoMode(W, H), "fleng");//, sf::Style::Fullscreen);
    window.setFramerateLimit(60);
    sf::RectangleShape rect(sf::Vector2f(W, H));
    // rect.setPosition(100, 100);
    rect.setFillColor(sf::Color::Green);
    sf::Shader shader;
    
    char dir[1024];
    getcwd( dir, sizeof( dir ) );
    printf( "CWD = %s", dir );
    if (!shader.loadFromFile("shaders/fleng.frag", sf::Shader::Fragment))
    {
        std::cerr << "YOU SUCKED(\n";
        return -1;
    }
    sf::RenderTexture renderTexture;
    renderTexture.create(W, H);
    renderTexture.clear();
    renderTexture.draw(rect);
    renderTexture.display();
    sf::Sprite sprite(renderTexture.getTexture());
    int t = 0;
    std::vector<Sph> sph;
    std::vector<Pln> pln;
    // sph.emplace_back(Sph(vec3(0, 0, 0), vec4(1.0, 1.0, 1., 1.), vec4(0.2, 0., 0., 0.)));
    // sph.emplace_back(Sph(vec3(1, 0, 0), vec4(1.0, 0.0, 0., 1.), vec4(0.2, 0., 0., 0.)));
    // sph.emplace_back(Sph(vec3(0, 1, 0), vec4(0.0, 1.0, 0., 1.), vec4(0.2, 0., 0., 0.)));
    // sph.emplace_back(Sph(vec3(0, 0, 1), vec4(0.0, 0.0, 1., 1.), vec4(0.2, 0., 0., 0.)));
    pln.emplace_back(Pln(vec3(0, -1, 0), vec4(1.0, 0.3, 1., 1.), vec3(0, 1, 0)));
    Camera cam;
    // sf::Clock cl;

    int MARCH = 200;

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
