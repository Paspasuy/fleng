uniform mat4 objects[50];
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
	return (abs(length(objects[i][0].xyz - pos)) - objects[i][2].y);
}

float plane_dist(vec3 pos, int i) {
	vec3 tmp = (pos - objects[i][0].xyz);
	return objects[i][2].y * tmp.x + objects[i][2].z * tmp.y + objects[i][2].w * tmp.z;
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
	return objects[j][2].yzw;
}
vec3 light_dir = normalize(vec3(0., -1., 1.));

vec3 serp_norm(int j) {
	return -light_dir;//vec3(0., 0., 0.);
}

vec3 obj_norm(vec3 ray_pos, int j) {
	if (objects[j][2].x == 0.) {
		return sphere_norm(ray_pos, j);
	}
	if (objects[j][2].x == 1.) {
		return plane_norm(j);
	}
	return serp_norm(j);
}

// const vec2 viewport = vec2(800, 800);
const vec4 sky = vec4(0.1, 0.1, 0.4, 1.0);
// const vec4 sky = vec4(0.4, 0.6, 1.0, 1.0);
const vec4 ground = vec4(0.5, 0.5, 0.5, 1.0);
const float mt_dist = 0.001;
// const float INF = 10000.;
// const float EPS = 0.00001;
// const int MARCH = 300;
// const int SUN_MARCH = 200;
const float INF = 100.;
const float EPS = 0.0001;
uniform int MARCH;
const int SUN_MARCH = 100;

float smin(float a, float b, float k) {
    float h = clamp(0.5 + 0.5*(a-b)/k, 0.0, 1.0);
    return mix(a, b, h) - k*h*(1.0-h);
}

vec4 gamma(vec4 color) {
	color.x = pow(color.x, 0.45);
	color.y = pow(color.y, 0.45);
	color.z = pow(color.z, 0.45);
	return color;
}

vec4 get_sky(vec3 ray_dir) {
	vec4 sun = vec4(0.95, 0.9, 1.0, 1.);
	sun *= max(0., pow(dot(-light_dir, ray_dir), 128.));
	return clamp(sun + sky, 0., 1.);
}


void main()
{
	// vec3 cam_dir = normalize(vec3(0., 0., 1.));
	vec3 yaxis = cross(cam_dir, xaxis);
	vec2 xy = (gl_TexCoord[0].xy - 0.5) * mt_sz;

	vec3 ray_pos = cam_pos;
	vec3 ray_dir = normalize(mt_dist * cam_dir + xaxis * xy.x + yaxis * xy.y);
	float lastd = 1.;
	int idx = 0;
	int iter = 0;
	float mind = INF, maxd = 0.;
	for (; iter < MARCH && lastd > EPS && lastd < INF; ++iter) {
		float dist = INF;
		for (int j = 0; j < obj_cnt; ++j) {
			float nd = obj_dist(warp(ray_pos), j);
			if (nd < dist) {
				dist = nd;
				idx = j;
			}
		}
		// dist = min(dist, smin(sphere_dist(ray_pos, 0), sphere_dist(ray_pos, 2), 0.5));
		ray_pos += ray_dir * dist;
		lastd = dist;
	}
	if (lastd >= INF) {
		gl_FragColor = gamma(get_sky(ray_dir));
		return;
	}
	float AO = 1.;
	AO = pow(1. - float(iter) / float(MARCH), 2.);
	float shadow = 1.;
	vec3 n = obj_norm(ray_pos, idx);
 	if (dot(-light_dir, n) > 0.) {
		vec3 sun_pos = ray_pos;
		lastd = 1.;
		for (int i = 0; i < SUN_MARCH && lastd > EPS && lastd < INF; ++i) {
			float dist = INF;
			for (int j = 0; j < obj_cnt; ++j) {
				if (j == idx) continue;
				float nd = obj_dist(warp(sun_pos), j);
				if (nd < dist) {
					dist = nd;
				}
			}
			sun_pos -= light_dir * dist;
			lastd = dist;
		}
		if (lastd <= EPS) {
			shadow = 0.8;
		}
	}
	float diffuse = max(0.0, dot(-light_dir, n));
	diffuse = clamp(diffuse * 0.6 + 0.4, 0., 1.);
	float specular = max(0.0, dot(reflect(ray_dir, n), -light_dir));
	vec4 color = objects[idx][1] * AO * clamp(diffuse * 0.9 + pow(specular, 64.) * 2., 0., 1.) * shadow;
	gl_FragColor = gamma(color);
}