package wav

import "core:fmt"
import "core:strings"
import "../pcm"
import ma "vendor:miniaudio"

// Decodes the file at path to stereo frames at pcm.SAMPLE_RATE, resampling a file at another rate. Prints why to stderr and returns false when it cannot.
decode :: proc(path: string) -> (frames: [][2]f32, ok: bool) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	decoder_config := ma.decoder_config_init(.f32, 2, pcm.SAMPLE_RATE)
	decoder: ma.decoder
	if result := ma.decoder_init_file(cpath, &decoder_config, &decoder); result != .SUCCESS {
		fmt.eprintfln("%s: %v", path, result)
		return nil, false
	}
	defer ma.decoder_uninit(&decoder)

	frame_count: u64
	if result := ma.decoder_get_length_in_pcm_frames(&decoder, &frame_count); result != .SUCCESS {
		fmt.eprintfln("%s: %v", path, result)
		return nil, false
	}
	if frame_count == 0 {
		fmt.eprintfln("%s is empty", path)
		return nil, false
	}

	frames = make([][2]f32, int(frame_count))
	frames_read: u64
	result := ma.decoder_read_pcm_frames(&decoder, raw_data(frames), frame_count, &frames_read)
	if frames_read != frame_count {
		fmt.eprintfln("%s: %v after %d of %d frames", path, result, frames_read, frame_count)
		delete(frames)
		return nil, false
	}
	return frames, true
}
