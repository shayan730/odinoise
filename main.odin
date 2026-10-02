package main

import "base:runtime"
import "core:fmt"
import "core:math"
import ma "vendor:miniaudio"
import rl "vendor:raylib"

Playback_Context :: struct {
	capture_ctx:  ^Audio_Capture_Context,
	rate_hz:      f32,
	depth:        f32,
	volume_boost: f32,
	lfo_phase:    f32,
	last_rms:     f32,
}

playback_callback :: proc "c" (
	pDevice: ^ma.device,
	pOutput: rawptr,
	pInput: rawptr,
	frameCount: u32,
) {
	context = runtime.default_context()

	if pDevice == nil || pOutput == nil do return

	ctx := cast(^Playback_Context)pDevice.pUserData
	if ctx == nil do return

	out_samples := (cast([^]f32)pOutput)[:frameCount * KATANA_CHANNELS]
	read_and_process_audio(
		ctx.capture_ctx,
		out_samples,
		ctx.rate_hz,
		ctx.depth,
		ctx.volume_boost,
		&ctx.lfo_phase,
	)

	ctx.last_rms = get_rms_level(out_samples)
}

main :: proc() {
	ma_ctx: ma.context_type
	if result := ma.context_init(nil, 0, nil, &ma_ctx); result != .SUCCESS {
		fmt.println("Failed to initialize miniaudio context:", result)
		return
	}
	defer ma.context_uninit(&ma_ctx)

	katana_ctx: Audio_Capture_Context
	katana_device: ma.device

	if !init_katana_capture(&katana_ctx, &katana_device, &ma_ctx) {
		fmt.println("Failed to setup Katana audio capture.")
		return
	}
	defer ma.device_uninit(&katana_device)
	defer ma.device_stop(&katana_device)

	pb_ctx := Playback_Context {
		capture_ctx  = &katana_ctx,
		rate_hz      = 6.0, // Tremolo Speed
		depth        = 0.90, // Tremolo Depth
		volume_boost = 6.0, // Output Volume Boost multiplier
		lfo_phase    = 0.0,
	}

	pb_config := ma.device_config_init(.playback)
	pb_config.playback.format = .f32
	pb_config.playback.channels = KATANA_CHANNELS
	pb_config.sampleRate = KATANA_SAMPLE_RATE
	pb_config.dataCallback = playback_callback
	pb_config.pUserData = &pb_ctx

	playback_device: ma.device
	if result := ma.device_init(&ma_ctx, &pb_config, &playback_device); result != .SUCCESS {
		fmt.println("Failed to initialize Mac playback device:", result)
		return
	}
	defer ma.device_uninit(&playback_device)
	defer ma.device_stop(&playback_device)

	ma.device_start(&katana_device)
	ma.device_start(&playback_device)

	rl.InitWindow(700, 500, "KATANA3 Tremolo & Gain Monitor")
	rl.SetTargetFPS(60)
	defer rl.CloseWindow()

	WAVEFORM_HISTORY :: 512
	waveform_display: [WAVEFORM_HISTORY]f32
	history_index: int = 0

	for !rl.WindowShouldClose() {
		latest_read :=
			(katana_ctx.write_index + CAPTURE_RING_BUFFER_SIZE - 1) % CAPTURE_RING_BUFFER_SIZE
		sample := katana_ctx.buffer[latest_read]
		processed_sample := apply_tremolo_effect(
			sample,
			pb_ctx.lfo_phase,
			pb_ctx.depth,
			pb_ctx.volume_boost,
		)

		waveform_display[history_index] = processed_sample
		history_index = (history_index + 1) % WAVEFORM_HISTORY

		current_rms := pb_ctx.last_rms

		rl.BeginDrawing()
		rl.ClearBackground(rl.Color{20, 24, 32, 255})

		scope_x: f32 = 40.0
		scope_y: f32 = 80.0
		scope_w: f32 = 560.0
		scope_h: f32 = 260.0

		rl.DrawRectangleRec({scope_x, scope_y, scope_w, scope_h}, rl.Color{12, 15, 20, 255})
		rl.DrawRectangleLinesEx(
			{scope_x, scope_y, scope_w, scope_h},
			2.0,
			rl.Color{45, 55, 75, 255},
		)
		rl.DrawLineEx(
			{scope_x, scope_y + scope_h / 2},
			{scope_x + scope_w, scope_y + scope_h / 2},
			1.0,
			rl.Color{30, 40, 55, 255},
		)

		rl.DrawText("KATANA3 TREMOLO / GAIN MONITOR", i32(scope_x), 30, 22, rl.WHITE)

		if current_rms > 0.002 {
			rl.DrawCircle(i32(scope_x) + 380, 42, 6, rl.GREEN)
			rl.DrawText("AUDIO PLAYBACK ACTIVE", i32(scope_x) + 395, 34, 14, rl.GREEN)
		} else {
			rl.DrawCircle(i32(scope_x) + 380, 42, 6, rl.DARKGRAY)
			rl.DrawText("WAITING FOR GUITAR...", i32(scope_x) + 395, 34, 14, rl.GRAY)
		}

		gain_scale: f32 = 450.0
		step_x := scope_w / f32(WAVEFORM_HISTORY - 1)

		for i in 0 ..< (WAVEFORM_HISTORY - 1) {
			idx1 := (history_index + i) % WAVEFORM_HISTORY
			idx2 := (history_index + i + 1) % WAVEFORM_HISTORY

			p1 := rl.Vector2 {
				scope_x + f32(i) * step_x,
				scope_y +
				(scope_h / 2) -
				math.clamp(waveform_display[idx1] * gain_scale, -scope_h / 2, scope_h / 2),
			}
			p2 := rl.Vector2 {
				scope_x + f32(i + 1) * step_x,
				scope_y +
				(scope_h / 2) -
				math.clamp(waveform_display[idx2] * gain_scale, -scope_h / 2, scope_h / 2),
			}
			line_color :=
				rl.Color{0, 212, 255, 255} if current_rms > 0.002 else rl.Color{0, 90, 160, 255}
			rl.DrawLineEx(p1, p2, 2.0, line_color)
		}

		meter_x := scope_x + scope_w + 20
		meter_height := math.clamp(current_rms * 300.0, 0.0, scope_h)

		rl.DrawRectangleRec({meter_x, scope_y, 20, scope_h}, rl.Color{30, 36, 48, 255})
		rl.DrawRectangleRec(
			{meter_x, scope_y + scope_h - meter_height, 20, meter_height},
			rl.Color{0, 212, 255, 255},
		)
		rl.DrawRectangleLinesEx({meter_x, scope_y, 20, scope_h}, 1.0, rl.GRAY)

		rl.DrawText(
			"Controls: UP/DOWN = Rate (Hz) | LEFT/RIGHT = Volume Boost",
			i32(scope_x),
			i32(scope_y + scope_h + 20),
			14,
			rl.LIGHTGRAY,
		)
		rl.DrawText(
			fmt.ctprintf("Rate: %.1f Hz", pb_ctx.rate_hz),
			i32(scope_x),
			i32(scope_y + scope_h + 45),
			18,
			rl.SKYBLUE,
		)
		rl.DrawText(
			fmt.ctprintf("Volume Boost: %.1fx", pb_ctx.volume_boost),
			i32(scope_x) + 220,
			i32(scope_y + scope_h + 45),
			18,
			rl.GOLD,
		)

		if rl.IsKeyDown(.UP) {
			pb_ctx.rate_hz = math.clamp(pb_ctx.rate_hz + 0.1, 0.5, 30.0)
		}
		if rl.IsKeyDown(.DOWN) {
			pb_ctx.rate_hz = math.clamp(pb_ctx.rate_hz - 0.1, 0.5, 30.0)
		}
		if rl.IsKeyDown(.RIGHT) {
			pb_ctx.volume_boost = math.clamp(pb_ctx.volume_boost + 0.1, 1.0, 30.0)
		}
		if rl.IsKeyDown(.LEFT) {
			pb_ctx.volume_boost = math.clamp(pb_ctx.volume_boost - 0.1, 1.0, 30.0)
		}

		rl.EndDrawing()
	}
}
