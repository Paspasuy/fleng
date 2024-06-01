uniform mat4 objects[50];
uniform float mt_sz;
const float mt_dist = 0.001;
uniform vec3 cam_pos, cam_dir, xaxis;
uniform int obj_cnt;

int MARCH = 200;
const float EPS = 0.0001;

vec4 gamma(vec4 color) {
	color.x = pow(color.x, 0.45);
	color.y = pow(color.y, 0.45);
	color.z = pow(color.z, 0.45);
	return color;
}

float Scale = 2.;
int Iterations = 18;
float Offset = 0.5;

float DE(vec3 z)
{
    float r;
    int n = 0;
    while (n < Iterations) {
       if(z.x+z.y<0.) z.xy = -z.yx; // fold 1
       if(z.x+z.z<0.) z.xz = -z.zx; // fold 2
       if(z.y+z.z<0.) z.zy = -z.yz; // fold 3	
       z = z*Scale - Offset*(Scale-1.0);
       n++;
    }
    return (length(z) ) * pow(Scale, -float(n));
}

float trace(vec3 from, vec3 direction) {
	float totalDistance = 0.0;
	int steps;
	for (steps=0; steps < MARCH; steps++) {
		vec3 p = from + totalDistance * direction;
		float distance = DE(p);
		totalDistance += distance;
		if (distance < EPS) break;
	}
	return 1.0-float(steps)/float(MARCH);
}

void main() {
	vec3 yaxis = cross(cam_dir, xaxis);
	vec2 xy = (gl_TexCoord[0].xy - 0.5) * mt_sz;

	vec3 ray_pos = cam_pos;
	vec3 ray_dir = normalize(mt_dist * cam_dir + xaxis * xy.x + yaxis * xy.y);
	float t = trace(ray_pos, ray_dir);
	gl_FragColor = gamma(vec4(t, t, t, 1.));
}