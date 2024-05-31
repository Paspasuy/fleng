uniform mat4 objects[50];
uniform float mt_sz;
uniform vec3 cam_pos, cam_dir, xaxis;
uniform int obj_cnt;

const float sq2 = 1.4142;
const float sq3 = 1.73205;

vec3 warp(vec3 pos) {
	// pos.x = mod(pos.x, 4.);
	// pos.y = mod(pos.y, 4.);
	// pos.z = mod(pos.z, 4.);
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
	// return 0.;
	float Scale = objects[i][2].y;
	float Offset = objects[i][2].z;
    float r;
    int n = 0;
    while (n < 4) {
       if (pos.x + pos.y < 0.) { pos.xy = -pos.yx; } // fold 1
       if (pos.x + pos.z < 0.) { pos.xz = -pos.zx; } // fold 2
       if (pos.y + pos.z < 0.) { pos.zy = -pos.yz; } // fold 3	
       pos = pos*Scale - Offset*(Scale-1.0);
       n++;
    }
    return (length(pos) ) * pow(Scale, -float(n));
}
float DE(vec3 p) {
	return min( length(p)-1.0 , length(p-vec3(2.0,0.0,0.0))-1.0 );
}

float obj_dist(vec3 pos, int j) {
	if (objects[j][2].x == 0.) {
		return sphere_dist(pos, j);
	}
	if (objects[j][2].x == 1.) {
		return plane_dist(pos, j);
	}
	if (objects[j][2].x == 2.) {
		return serp_dist(pos, j);
	}
}

vec3 sphere_norm(vec3 ray_pos, int j) {
	return normalize(warp(ray_pos) - objects[j][0].xyz);
}

vec3 plane_norm(int j) {
	return objects[j][2].yzw;
}

vec3 serp_norm(int j) {
	return normalize(vec3(1., 1., 1.));
}

vec3 obj_norm(vec3 ray_pos, int j) {
	if (objects[j][2].x == 0.) {
		return sphere_norm(ray_pos, j);
	}
	if (objects[j][2].x == 1.) {
		return plane_norm(j);
	}
	if (objects[j][2].x == 2.) {
		return serp_norm(j);
	}
}

// const vec2 viewport = vec2(800, 800);
const vec4 sky = vec4(0.4, 0.6, 1.0, 1.0);
const vec4 ground = vec4(0.5, 0.5, 0.5, 1.0);
const float mt_dist = 0.001;
const float INF = 1000.;
const float EPS = 0.0001;
const int MARCH = 200;
const int SUN_MARCH = 100;
vec3 light_dir = normalize(vec3(0., -1., 1.));

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
	float cnt = 0.;
	for (int i = 0; i < MARCH && lastd > EPS && lastd < INF; ++i) {
		float dist = INF;
		for (int j = 0; j < obj_cnt; ++j) {
			float nd = obj_dist(warp(ray_pos), j);
			if (nd < dist) {
				dist = nd;
				idx = j;
			}
		}
		cnt += 1.;
		dist = min(dist, smin(sphere_dist(ray_pos, 0), sphere_dist(ray_pos, 1), 0.5));
		ray_pos += ray_dir * dist;
		lastd = dist;
	}
	// float x = cnt / float(MARCH);
	// gl_FragColor = gamma(objects[5][1].xyzw);
	// return;
	if (lastd >= INF) {
		gl_FragColor = gamma(get_sky(ray_dir));
		return;
	}
	// if (obj_cnt == 2) {
	// 	gl_FragColor = gamma(vec4(0., 0., 0.0, 1.0));
	// 	return;
	// }
	float shadow = 1.;
	vec3 n = obj_norm(ray_pos, idx);
/*	if (dot(-light_dir, n) > 0.) {
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
		if (lastd < EPS) {
			shadow = 0.8;
		}
	}*/
	float diffuse = max(0.0, dot(-light_dir, n));
	diffuse = clamp(diffuse * 0.6 + 0.4, 0., 1.);
	float specular = max(0.0, dot(reflect(ray_dir, n), -light_dir));
	vec4 color = objects[idx][1] * clamp(diffuse * 0.9 + pow(specular, 64.) * 2., 0., 1.) * shadow;
	gl_FragColor = gamma(color);
}