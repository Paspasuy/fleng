uniform mat4 objects[50];
uniform float time;
uniform float mt_sz;
uniform vec3 cam_pos, cam_dir, xaxis;
uniform int obj_cnt;

const float sq2 = 1.4142;
const float sq3 = 1.73205;

vec3 warp(vec3 pos) {
  // pos.xz = mod(pos.xz, 3.) - vec2(1.5);
  return pos;
}

float sphere_dist(vec3 pos, int i) {
  return ((abs(length(objects[i][0].xyz - pos)) - objects[i][2].y));
}

float plane_dist(vec3 pos, int i) {
  return dot(pos - objects[i][0].xyz, normalize(objects[i][2].yzw));
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
  return normalize(objects[j][2].yzw);
}
vec3 light_dir = normalize(vec3(0., -1., 1.));

vec3 fractal_norm(int j) {
  return -light_dir;
}

vec3 obj_norm(vec3 ray_pos, int j) {
  if (objects[j][2].x == 0.) {
    return sphere_norm(ray_pos, j);
  }
  if (objects[j][2].x == 1.) {
    return plane_norm(j);
  }
  return fractal_norm(j);
}

// const vec2 viewport = vec2(800, 800);
const vec4 sky = vec4(0.4, 0.6, 1.0, 1.0);
const vec4 ground = vec4(0.5, 0.5, 0.5, 1.0);
const float mt_dist = 0.001;
const float INF = 1000.;
const float EPS = 0.00001;
uniform int MARCH;

const int REFLECT_COUNT = 4;

float smin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5*(a-b)/k, 0.0, 1.0);
    return mix(a, b, h) - k*h*(1.0-h);
}

vec4 gamma(vec4 color) {
//  if (mod(time, 1.) < .5) {
    color.x = pow(color.x, 0.45);
    color.y = pow(color.y, 0.45);
    color.z = pow(color.z, 0.45);
/*  } else {
    // gamma correction
    color = max( vec3(0), color - 0.004);
    color = (color*(6.2*color + .5)) / (color*(6.2*color+1.7) + 0.06);
  }
*/
  return color;

}


vec4 get_sky(vec3 ray_dir) {
  vec4 sun = vec4(0.95, 0.9, 1.0, 1.);
  sun *= max(0., pow(dot(-light_dir, ray_dir), 128.));
  return clamp(sun + sky, 0., 1.);
}

vec4 get_floor(vec3 ray_pos, vec3 ray_dir) {
  return objects[0][1];
}

// Heavily rely that objects[0] is floor
vec4 get_surround(vec3 ray_pos, vec3 ray_dir) {
  vec4 result = get_sky(ray_dir);
  if (ray_dir.y < 0.) {
    result *= get_floor(ray_pos, ray_dir);
  }
  return result;
}


void main()
{
  vec3 yaxis = cross(cam_dir, xaxis);
  vec2 xy = (gl_TexCoord[0].xy - 0.5) * mt_sz;

  vec3 ray_pos = cam_pos;
  vec3 ray_dir = normalize(mt_dist * cam_dir + xaxis * xy.x + yaxis * xy.y);
  float lastd = 1.;
  int idx = 0;
  float mind = INF, maxd = 0.;
  float AO = 1.;
  
  vec4 ray_color = vec4(1., 1., 1., 1.);

  for (int iter_refl = 0; iter_refl < REFLECT_COUNT; ++iter_refl) {

    int citer = 0;
    lastd = 1.;

    // March to the nearest object
    for (; citer < MARCH && lastd > EPS && lastd < INF; ++citer) {
      float dist = INF;
      for (int j = 0; j < obj_cnt; ++j) {
        float nd = obj_dist(warp(ray_pos), j);
        if (nd < dist) {
          dist = nd;
          idx = j;
        }
      }
      ray_pos += ray_dir * dist;
      lastd = dist;
    }

    // Ray points to the sky
    if (lastd >= INF) {
      gl_FragColor = gamma(get_sky(ray_dir) * ray_color * AO);
      return;
    }

    // Do not reflect further if hit fractal
    if (objects[idx][2].x >= 100.) {
      ray_color *= objects[idx][1];
      AO = pow(1. - float(citer) / float(MARCH), 2.);
      gl_FragColor = gamma(ray_color * AO);
      return;
    }

    // Failed approaching to any object
    if (citer == MARCH) {
      AO = 1.;
      break;
    }

    // Object reflects ray
    ray_color *= objects[idx][1];
    ray_dir = reflect(ray_dir, obj_norm(ray_pos, idx));
    ray_pos += ray_dir * abs(EPS) * 2.;
    
  }
  gl_FragColor = gamma(get_surround(ray_pos, ray_dir) * ray_color * AO);
  return;
}

