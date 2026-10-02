package main

import "base:runtime"
import "core:fmt"
import "core:math"
import "core:strings"
import ma "vendor:miniaudio"

KATANA_CHANNELS :: 2
KATANA_SAMPLE_RATE :: 44100
CAPTURE_RING_BUFFER_SIZE :: 16384

Audio_Capture_Context :: struct {
	buffer:       [CAPTURE_RING_BUFFER_SIZE]f32,
	write_index:  u32,
	read_index:   u32,
	sample_count: u32,
}

katana_capture_callback :: proc "c" (
	pDevice: ^ma.device,
	pOutput: rawptr,
	pInput: rawptr,
	frameCount: u32,
) {
	context = runtime.default_context()

	if pDevice == nil || pInput == nil do return

	ctx := cast(^Audio_Capture_Context)pDevice.pUserData
	if ctx == nil do return

	samples := (cast([^]f32)pInput)[:frameCount * KATANA_CHANNELS]

	for sample in samples {
		ctx.buffer[ctx.write_index] = sample
		ctx.write_index = (ctx.write_index + 1) % CAPTURE_RING_BUFFER_SIZE

		if ctx.sample_count < CAPTURE_RING_BUFFER_SIZE {
			ctx.sample_count += 1
		} else {
			ctx.read_index = (ctx.read_index + 1) % CAPTURE_RING_BUFFER_SIZE
		}
	}
}

find_katana_device_id :: proc(
	ma_context: ^ma.context_type,
) -> (
	device_id: ma.device_id,
	found: bool,
) {
	pPlaybackInfos: [^]ma.device_info
	playbackCount: u32
	pCaptureInfos: [^]ma.device_info
	captureCount: u32

	result := ma.context_get_devices(
		ma_context,
		&pPlaybackInfos,
		&playbackCount,
		&pCaptureInfos,
		&captureCount,
	)

	if result != .SUCCESS {
		fmt.println("Failed to enumerate audio devices:", result)
		return device_id, false
	}

	capture_devices := pCaptureInfos[:captureCount]

	fmt.println("--- Searching for Katana Audio Interface ---")
	for &dev in capture_devices {
		raw_name := strings.clone_from_cstring(transmute(cstring)&dev.name[0])
		defer delete(raw_name)

		fmt.printfln("  - Device: %s", raw_name)

		lower_name := strings.to_lower(raw_name)
		defer delete(lower_name)

		if strings.contains(lower_name, "katana") || strings.contains(lower_name, "boss") {
			fmt.printfln("--> Matched Katana USB Device: %s", raw_name)
			return dev.id, true
		}
	}
	fmt.println("--------------------------------------------")

	return device_id, false
}

init_katana_capture :: proc(
	capture_ctx: ^Audio_Capture_Context,
	device: ^ma.device,
	ma_context: ^ma.context_type,
) -> bool {
	katana_id, found := find_katana_device_id(ma_context)

	device_config := ma.device_config_init(.capture)
	device_config.capture.format = .f32
	device_config.capture.channels = KATANA_CHANNELS
	device_config.sampleRate = KATANA_SAMPLE_RATE
	device_config.dataCallback = katana_capture_callback
	device_config.pUserData = capture_ctx

	if found {
		device_config.capture.pDeviceID = &katana_id
	} else {
		fmt.println(
			"Warning: KATANA interface not explicitly detected. Falling back to default capture device.",
		)
	}

	if result := ma.device_init(ma_context, &device_config, device); result != .SUCCESS {
		fmt.println("Failed to initialize capture device:", result)
		return false
	}

	return true
}

apply_tremolo_effect :: proc(sample: f32, lfo_phase: f32, depth: f32, volume_boost: f32) -> f32 {
	lfo := (math.sin(lfo_phase) + 1.0) * 0.5
	amplitude_mod := (1.0 - depth) + (lfo * depth)

	// Apply tremolo AND boost overall signal amplitude
	return sample * amplitude_mod * volume_boost
}

read_and_process_audio :: proc(
	ctx: ^Audio_Capture_Context,
	output: []f32,
	rate_hz: f32,
	depth: f32,
	volume_boost: f32,
	lfo_phase: ^f32,
) -> u32 {
	read_count: u32 = 0
	req_samples := u32(len(output))

	phase_step := (2.0 * math.PI * rate_hz) / f32(KATANA_SAMPLE_RATE)

	for read_count < req_samples && ctx.sample_count > 0 {
		raw_sample := ctx.buffer[ctx.read_index]
		ctx.read_index = (ctx.read_index + 1) % CAPTURE_RING_BUFFER_SIZE
		ctx.sample_count -= 1

		output[read_count] = apply_tremolo_effect(raw_sample, lfo_phase^, depth, volume_boost)

		lfo_phase^ += phase_step
		if lfo_phase^ >= 2.0 * math.PI {
			lfo_phase^ -= 2.0 * math.PI
		}

		read_count += 1
	}

	for i in read_count ..< req_samples {
		output[i] = 0.0
	}

	return read_count
}

get_rms_level :: proc(samples: []f32) -> f32 {
	if len(samples) == 0 do return 0.0
	sum: f32 = 0.0
	for s in samples {
		sum += s * s
	}
	return math.sqrt(sum / f32(len(samples)))
}
