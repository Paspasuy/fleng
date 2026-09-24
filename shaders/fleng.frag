#version 120
const int SZ = 110;
uniform mat4 objects[SZ];
uniform mat4 obj_indices[SZ];
uniform float time;
uniform float mt_sz;
uniform vec3 cam_pos, cam_dir, xaxis;
uniform int obj_cnt;

uniform sampler2D video;
uniform int video_o;

uniform sampler2D image2;
uniform int image2_o;
const float sq2 = 1.4142;
const float sq3 = 1.73205;

float last_time;

/* uint needs GLSL 1.30; macOS SFML only gets a GLSL 1.20 context
uint seed;

void initSeed()
{
    seed = uint(gl_FragCoord.x) * 1973u +
           uint(gl_FragCoord.y) * 9277u +
           uint(time * 1000.0) * 26699u;
}

float rand()
{
    seed = seed * 1664525u + 1013904223u; // LCG
    return float(seed) / 4294967296.0;
}
*/


float rand(vec2 co) {
//   vec2 co = vec2(time, time);
   return fract(sin(dot(co.xy,vec2(12.9898,78.233))) * 43758.5453);
}

/*
double rand(vec2 co) {
    double a = 12.9898;
    double b = 78.233;
    float c = 43758.5453;
    float dt= dot(co.xy ,vec2(a,b));
    float sn= mod(dt,3.14);
    return fract(sin(sn) * c) / 2;
}
*/
/*
highp float rand(vec2 co)
{
    highp float a = 12.9898;
    highp float b = 78.233;
    highp float c = 43758.5453;
    highp float dt= dot(co.xy ,vec2(a,b));
    highp float sn= mod(dt,3.14);
    return fract(sin(sn) * c);
}
*/
vec3 warp(vec3 pos) {
//  pos.xz = mod(pos.xz, 16.) - vec2(1.5);
  return pos;
}

float sphere_dist(vec3 pos, int i) {
  return length(objects[i][0].xyz - pos) - objects[i][2].y;
}

float plane_dist(vec3 pos, int i) {
  return dot(objects[i][0].xyz - pos, -objects[i][2].yzw);
}

float cuboid_dist(vec3 pos, int i) {
  vec3 rel = abs(pos - objects[i][0].xyz) - objects[i][2].yzw;
  // first term for case when dot is indide cube
  return min(max(rel.x, max(rel.y, rel.z)), 0.0) + length(max(rel, 0.0));
}

float serp_dist(vec3 pos, int i)
{
  float Scale = objects[i][2].y;
  float Iterations = objects[i][2].z;
  float Offset = objects[i][2].w;
  vec3 z = pos - objects[i][0].xyz;
  float r;
  float n = 0.;
  while (n < Iterations) {
    if(z.x+z.y<0.) z.xy = -z.yx; // fold 1
    if(z.x+z.z<0.) z.xz = -z.zx; // fold 2
    if(z.y+z.z<0.) z.zy = -z.yz; // fold 3  
    z = z*Scale - Offset*(Scale-1.0);
    n += 1.;
  }
  return (length(z) ) * pow(Scale, -float(n));
}


float mandelbulb_dist(vec3 pos, int el) {
  pos -= objects[el][0].xyz;
  float Iterations = objects[el][2].z;
  float Bailout = 100.;
  float Power = 8.;
  vec3 z = pos;
  float dr = 1.0;
  float r = 0.0;
  for (float i = 0.; i < Iterations; i += 1.) {
    r = length(z);
    if (r>Bailout) break;
    
    // convert to polar coordinates
    float theta = acos(z.z/r);
    float phi = atan(z.y,z.x);
    dr =  pow( r, Power-1.0)*Power*dr + 1.0;
    
    // scale and rotate the point
    float zr = pow( r,Power);
    theta = theta*Power;
    phi = phi*Power;
    
    // convert back to cartesian coordinates
    z = zr*vec3(sin(theta)*cos(phi), sin(phi)*sin(theta), cos(theta));
    z+=pos;
  }
  return 0.5*log(r)*r/dr;
}

void sphereFold(inout vec3 z, inout float dz) {
  float minRadius2 = 2.;
  float fixedRadius2 = 3.;
  float r2 = dot(z,z);
  if (r2<minRadius2) { 
    // linear inner scaling
    float temp = (fixedRadius2/minRadius2);
    z *= temp;
    dz*= temp;
  } else if (r2<fixedRadius2) { 
    // this is the actual sphere inversion
    float temp =(fixedRadius2/r2);
    z *= temp;
    dz*= temp;
  }
}

void boxFold(inout vec3 z, inout float dz) {
  float foldingLimit = 0.3;
  z = clamp(z, -foldingLimit, foldingLimit) * 2.0 - z;
}

float mandelbox_dist(vec3 z, int el)
{
  float Scale = 1.7;
  // float Scale = 2.25;
  int Iterations = 30;
  vec3 offset = z;
  float dr = 1.0;
  for (int n = 0; n < Iterations; n++) {
    boxFold(z,dr);       // Reflect
    sphereFold(z,dr);    // Sphere Inversion
    z=Scale*z + offset;  // Scale & Translate
    dr = dr*abs(Scale)+1.0;
  }
  float r = length(z);
  return r/abs(dr);
}


float obj_dist(vec3 pos, int j) {
  if (objects[j][2].x == 0.) {
    return sphere_dist(pos, j);
  }
  if (objects[j][2].x == 1.) {
    return plane_dist(pos, j);
  }
  if (objects[j][2].x == 2.) {
    return cuboid_dist(pos, j);
  }
  if (objects[j][2].x == 50.) {
    return sphere_dist(pos, j);
  }
  if (objects[j][2].x == 100.) {
    return serp_dist(pos, j);
  }
  if (objects[j][2].x == 101.) {
    return mandelbulb_dist(pos, j);
  }
  if (objects[j][2].x == 102.) {
    return mandelbox_dist(pos, j);
  }
}

vec3 sphere_norm(vec3 ray_pos, int j) {
  return normalize(warp(ray_pos) - objects[j][0].xyz);
}

vec3 plane_norm(int j) {
  return objects[j][2].yzw;
}

vec3 cuboid_norm(vec3 ray_pos, int j) {
  vec3 rel = ray_pos - objects[j][0].xyz;
  vec3 signs = abs(rel) / rel;
  rel = abs(abs(rel) - objects[j][2].yzw);
  float mn = min(rel.x, min(rel.y, rel.z));
  if (abs(rel.x - mn) < 0.00001) {
    rel.xyz = vec3(1., 0., 0.);
  } else if (abs(rel.y - mn) < 0.00001) {
    rel.xyz = vec3(0., 1., 0.);
  } else {
    rel.xyz = vec3(0., 0., 1.);
  }
  return normalize(rel * signs);
}

vec3 light_dir = normalize(vec3(0.3, -0.3, 0.7));

vec3 fractal_norm(int j) {
  return -light_dir;
}

vec3 obj_norm(vec3 ray_pos, int j) {
  if (objects[j][2].x == 0.) {
    return sphere_norm(ray_pos, j);
  }
  if (objects[j][2].x == 50.) {
    return sphere_norm(ray_pos, j);
  }
  if (objects[j][2].x == 1.) {
    return plane_norm(j);
  }
  if (objects[j][2].x == 2.) {
    return cuboid_norm(ray_pos, j);
  }
  return fractal_norm(j);
}

// const vec2 viewport = vec2(800, 800);
const vec3 sky = vec3(0.4, 0.6, 0.95);
const vec3 sun = vec3(1.0, 1.0, 0.4);
const float mt_dist = 0.001;
const float INF = 1000.;
const float EPS = 0.00001;
uniform int MARCH;

const int REFLECT_COUNT = 30;

float smin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5*(a-b)/k, 0.0, 1.0);
    return mix(a, b, h) - k*h*(1.0-h);
}

vec4 gamma(vec4 color) {
  color = smoothstep(0.0,1.0,color);
  float white = 9.0;
  float exposure = 0.3;
  color *= white * exposure;
  color = (color * (1.0 + color / white / white)) / (1. + color);

  color.x = pow(color.x, 0.45);
  color.y = pow(color.y, 0.45);
  color.z = pow(color.z, 0.45);
  color.w = 1.;
  return color;

}


vec3 get_sky(vec3 ray_dir) {
  vec3 cur_sun = sun;
  cur_sun *= max(0., pow(dot(-light_dir, ray_dir), 128.));
  return clamp(cur_sun + sky, 0., 1.);
}

vec3 get_floor(vec3 ray_pos, vec3 ray_dir) {
  return objects[0][1].xyz;
}

// Heavily relies on that objects[0] is floor
vec3 get_specular_surround(vec3 ray_pos, vec3 ray_dir) {
  vec3 result = get_sky(ray_dir);
  if (dot(ray_dir, objects[0][2].yzw) < 0.) {
    result *= get_floor(ray_pos, ray_dir);
  }
  return result;
}

vec2 get_cuboid_tc(int idx, vec3 pos) {
  vec3 relpos = pos - objects[idx][0].xyz;
  vec3 rad = objects[idx][2].yzw;
  return (-relpos.xy / rad.xy + vec2(1.)) / 2;
//  return vec2(relpos.x / rad.x, relpos.z / rad.z);
}


void raymarch(inout int citer, inout float lastd, inout vec3 ray_pos, inout vec3 ray_dir, inout int idx, int start_obj) {
  for (; citer < MARCH && abs(lastd) > EPS && lastd < INF; ++citer) {
    float dist = INF;
    if (start_obj == -1) {
      for (int j = 0; j < obj_cnt; ++j) {
        float nd = obj_dist(warp(ray_pos), j);
        if (nd < dist) {
          dist = nd;
          idx = j;
        }
      }
    } else {
      for (int j = 0; j < obj_cnt; ++j) {
      //for (int i = 0; i < 16; ++i) {
      //  int j = (int)obj_indices[start_obj][i / 4][i % 4];
        float nd = obj_dist(warp(ray_pos), j);
        if (nd < dist) {
          dist = nd;
          idx = j;
        }
      }
    }
    ray_pos += ray_dir * dist;
    lastd = dist;
  }
}

vec3 get_diffuse_surround(vec3 ray_pos, vec3 ray_dir) {
  // ray pos is for checkers floor
  // return get_surround(ray_pos, ray_dir).xyz * pow(mod(time, 1.), 2.3);//0.4;
  return get_specular_surround(ray_pos, ray_dir) / 20.;//* pow(mod(time, 1.), 2.3) / 20;//0.4;
}

// This function analitically resolves problems occuring when raymarching takes too many iterations
vec3 get_surround_for_far(vec3 ray_pos, vec3 ray_dir) {
  vec3 floor_norm = objects[0][2].yzw;
  if (dot(ray_dir, floor_norm) < 0.) {
    vec3 refl = reflect(ray_dir, floor_norm);
    vec3 intersection_pt = ray_pos + ray_dir * plane_dist(ray_pos, 0) / dot(-floor_norm, ray_dir);
    return mix(
        // Intersect ray with plane and get diffuse from there
        get_diffuse_surround(intersection_pt, refl),
        get_sky(refl),
        1.
        //objects[0][1].w
        ) * objects[0][1].xyz;
  }
  return get_sky(ray_dir);
}



vec3 dumb_diffuse_color(vec3 ray_pos, vec3 ray_dir, int obj_idx) {
  vec3 color = vec3(0.);
  vec3 surface_norm = obj_norm(ray_pos, obj_idx);
  for (int j = 0; j < obj_cnt; ++j) {
    if (j == obj_idx) continue;
    vec3 to_obj = objects[j][0].xyz - ray_pos;
    if (dot(surface_norm, to_obj) < 0.) continue;
    float dist = obj_dist(warp(ray_pos), j) * 3;
    dist *= dist;
    color += dot(surface_norm, to_obj) * objects[j][1].xyz / (0.5 + dist);
  }
//  if (mod(time, 1) > 0.5)
//  color += get_diffuse_surround(ray_pos, reflect(ray_dir, surface_norm));
  color = clamp(color, 0., 1.);

  color *= objects[obj_idx][1].xyz;
  return color;

}

// Returns a random unit vector within a cone of angle alpha
// around the direction `dir` (dir must be normalized)
//
// rnd.x, rnd.y must be uniform random numbers in [0, 1]
vec3 randomDirectionInCone(vec3 dir, float alpha, vec2 rnd)
{
    // 1. Sample spherical cap
    float cosAlpha = cos(alpha);
    float cosTheta = mix(cosAlpha, 1.0, rnd.x); // uniform in cos(theta)
    float sinTheta = sqrt(1.0 - cosTheta * cosTheta);

    float phi = 2.0 * 3.14159265359 * rnd.y;

    // Local-space direction (Z is cone axis)
    vec3 localDir = vec3(
        cos(phi) * sinTheta,
        sin(phi) * sinTheta,
        cosTheta
    );

    // 2. Build orthonormal basis around dir
//    vec3 up = abs(dir.z) < 0.999 ? vec3(0.0, 0.0, 1.0)
//                                 : vec3(1.0, 0.0, 0.0);

    vec3 up = vec3(0.0, 0.0, 1.0);
    vec3 tangent   = normalize(cross(up, dir));
    vec3 bitangent = cross(dir, tangent);

    // 3. Transform to world space
    return normalize(
        tangent   * localDir.x +
        bitangent * localDir.y +
        dir       * localDir.z
    );
}


void main()
{
  vec3 yaxis = cross(cam_dir, xaxis);
  vec2 xy = (gl_TexCoord[0].xy - 0.5) * mt_sz;

  vec3 ray_pos = cam_pos;
  vec3 ray_dir = normalize(mt_dist * cam_dir + xaxis * xy.x + yaxis * xy.y);
  float lastd = 1.;
  int idx = 0;
  float AO = 1.;
  
  vec4 ray_color = vec4(1., 1., 1., 1.);
  vec4 sum_color = vec4(0., 0., 0., 1.);
  int start_obj = -1;

  for (int iter_refl = 0; iter_refl < REFLECT_COUNT; ++iter_refl) {

    int citer = 0;
    lastd = 1.;

    // March to the nearest object
    raymarch(citer, lastd, ray_pos, ray_dir, idx, start_obj);

    // Ray points to the sky
    if (lastd >= INF) {
      ray_color.xyz *= get_sky(ray_dir).xyz;
      sum_color.xyz += ray_color.xyz;// * ray_color.w;
      //sum_color.xyz += get_surround_for_far(ray_pos, ray_dir) * ray_color.w;
      gl_FragColor = gamma(sum_color * AO);
      return;
    }

    // Do not reflect further if hit fractal
    if (objects[idx][2].x >= 100.) {
      AO = pow(1. - float(citer) / float(MARCH), 2.);
      ray_color *= objects[idx][1] * AO;
      sum_color.xyz += ray_color.xyz;// * ray_color.w;
      gl_FragColor = gamma(sum_color);
      return;
    }

    // Failed approaching to any object — either sky or floor
    if (citer == MARCH) {
      sum_color.xyz += ray_color.xyz * get_surround_for_far(ray_pos, ray_dir);// * ray_color.w;
      gl_FragColor = gamma(sum_color * AO);
//      gl_FragColor = vec4(0.);
      return;
    }

    if (idx == image2_o) {
      vec2 tpos = get_cuboid_tc(idx, ray_pos);
      vec3 tcol = texture2D(image2, tpos).rgb;
      ray_color.xyz *= tcol;
      sum_color.xyz += ray_color.xyz;
      gl_FragColor = sum_color * AO;
      return;
    }

    if (idx == video_o) {
      vec2 tpos = get_cuboid_tc(idx, ray_pos);
      vec3 tcol = texture2D(video, tpos).rgb;
      ray_color.xyz *= tcol;
      sum_color.xyz += ray_color.xyz;
      gl_FragColor = sum_color * AO;
      return;
    }



    // Check if this is light source
    if (objects[idx][1].w < 0.) {
      if (objects[idx][2].x != 50.) {
        ray_color.xyz *= objects[idx][1].xyz;
        sum_color.xyz += ray_color.xyz;// * ray_color.w;
        gl_FragColor = gamma(sum_color * AO);
        return;
      }
      // Refracting shpere
    }
//    vec3 diffuse_color = dumb_diffuse_color(ray_pos, ray_dir, idx);

    // Object reflects color
//    sum_color.xyz += diffuse_color * (1. - objects[idx][1].w) * ray_color.w;

    if (objects[idx][2].x != 50.) {
      ray_color.xyz *= objects[idx][1].xyz;
      // Reflect ray
      ray_dir = reflect(ray_dir, obj_norm(ray_pos, idx));
  //    vec2 rv = (vec2(sin(time+10*ray_pos.x), sin(time+10*ray_pos.y)) + 1) / 2;
      vec2 rv = vec2(rand(ray_pos.xy * sin(time * 13.2347)), rand(ray_pos.xy * cos(time)));
      // vec2 rv = vec2(rand(ray_pos) * cos(time * 1238.), rand(ray_pos) * sin(time * 3. + 12.));
      // vec2 rv = vec2(mix(rand(ray_pos), rand(), 0.8), mix(rand(ray_pos), rand(), 0.8));
      //vec2 rv = vec2(rand(ray_pos), rand(ray_pos));
      // vec2 rv = vec2(rand(), rand());
  // TODo: remove black area
//      if (abs(length(dot(ray_dir, obj_norm(ray_pos, idx)))) >  0.05) {
        // ray_dir = randomDirectionInCone(ray_dir, (sin(time * 5) + 7) / 80 * (1-objects[idx][1].w)  * 2* 1.5707963, rv);
        ray_dir = randomDirectionInCone(ray_dir, (1-objects[idx][1].w)  * 1.5707963/  3, rv);
//      }

      ray_pos += ray_dir * abs(EPS) * 30.;
    } else {
      // Refract ray
      vec3 on = obj_norm(ray_pos, idx);
      vec3 new_ray_dir = refract(ray_dir, on, 1. / (1. - objects[idx][1].w));
      float k = abs(dot(ray_dir, on));
//      if (k <  0.65) {
//        if (rand(ray_pos) * (3 + cos(time)) / 4 < (0.65 - k) * 5)
//        new_ray_dir = reflect(ray_dir, on);
//      }
//      ray_dir = new_ray_dir;
//      vec3 ray_pos_half = ray_pos + ray_dir * 1. * objects[idx][2].y;
/*      if (length(ray_pos_half - objects[idx][0].xyz) > objects[idx][2].y) {
        ray_dir = reflect(ray_dir, obj_norm(ray_pos, idx));
        ray_pos += ray_dir * abs(EPS) * 30.;
      } else {
      */
//        vec3 relpos = normalize(ray_pos - objects[idx][0].xyz);
//        float sina = length(cross(ray_dir, obj_norm(ray_pos, idx)));
        vec3 to_center = objects[idx][0].xyz - ray_pos;
        vec3 path_inside = ray_dir * 2 * dot(to_center, ray_dir);
        ray_pos += path_inside;
        float coeff = 1 - pow(length(path_inside) / length(to_center) /  2, 2.) /  2;
        ray_color.xyz *= coeff * objects[idx][1].xyz;
        ray_dir = new_ray_dir;
        ray_pos += ray_dir * EPS * 30;
      //}
    }
    start_obj = idx;
  }
  // Found no light source
  gl_FragColor = sum_color;//vec4(1.);
//  gl_FragColor = vec4(1.);
  return;
}

