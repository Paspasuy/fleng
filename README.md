# Fleng

## How to build & run
1. Install SFML, FFmpeg and Zig 0.16 (`brew install sfml ffmpeg zig`)
2. `make`
3. Settings live in `fleng.toml` (read from the working directory, or pass a path: `./build/release/fleng my.toml`)
4. `./build/release/fleng --screenshot out.png 5` saves a frame after 5 seconds and exits

Keys: WASD move, arrows turn, 1/2 roll, -/= field of view, 3/4 march steps, 5/6 speed,
P accumulate frames, R restart the water, T pause the water, F12 screenshot.

Water is simulated by the Zig library in `sim/` (see `docs/water-plan.md`).

## License
Absolutely closed-source. Looking into the source code is **STRICTLY PROHIBITED**.
**THE SOFTWARE IS NOT PROVIDED**.

**IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR DAMAGES ARISING FROM LOOKING INTO THE SOURCE CODE.**

## Roadmap :rocket:

- 2025 Q4: :fire: Texturing cuboids
- 2026 Q4: :fire: Rotating Obama prism
- 2027 Q4: :fire: GIF "Vot komu-to delat' nechego"
- 2028: :fire: MP4 support, include Subway Surfers gameplay recording for Gen-Z users
- 2029: :fire: Support 3d letters
- 2030: :zap: Finally: RTX Terminal
- 2035: Introducing Xorg client
- 2040: Rewrite into :rocket: Rust :zap: and compile to wasm and publish on gh pages

