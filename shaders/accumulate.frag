uniform sampler2D currentFrame;
uniform sampler2D previousAccum;
uniform float invN;        // 1.0 / n
uniform float prevFactor;  // (n - 1) / n

void main()
{
    vec2 uv = gl_TexCoord[0].xy;
//    vec4 col = gl_FragCoord;

    vec4 curr = texture2D(currentFrame, uv);
    vec4 prev = texture2D(previousAccum, uv);

     gl_FragColor = curr * invN + prev * prevFactor;
//    gl_FragColor = gl_FragColor * invN + prev * prevFactor;
//    gl_FragColor = vec4(0.);
}

