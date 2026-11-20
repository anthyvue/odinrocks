// The settings of the player, kept in settings.json.
package config

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "../pedals"

PATH :: "settings.json"
MAX_AV_OFFSET_MS :: 2000
// Gains are tenths, so 10 is unity.
MAX_GAIN_TENTHS :: 20

Settings :: struct {
	av_offset_ms:       int,
	guitar_gain_tenths: int,
	song_gain_tenths:   int,
	guitar_channel:     int,
	asio_driver:        string,
	draw_hit_flash:     bool,
	// Borderless fullscreen on the current monitor. Off is a resizable window.
	borderless:         bool,
	// The file name of the rig in pedals.RIGS_DIR that the guitar plays through. main replaces one that is not there.
	rig:                string,
	pedals:             pedals.Knobs,
	// The tuning that the player last tuned the guitar to: the MIDI note of each open string, from the high string, like a Songsterr track.
	// A guitar of a song in another tuning opens the tuner before it plays.
	tuning:             []int,
}

@(rodata)
E_STANDARD := [6]int{64, 59, 55, 50, 45, 40}

DEFAULTS :: Settings {
	guitar_gain_tenths = 7,
	song_gain_tenths   = 7,
	guitar_channel     = 1,
	draw_hit_flash     = true,
	borderless         = true,
	pedals             = pedals.DEFAULT_KNOBS,
}

// A setting that the file lacks gets its default, and one outside its range is moved inside it. A missing file is written with the defaults.
load :: proc() -> Settings {
	settings := DEFAULTS
	data, err := os.read_entire_file(PATH, context.allocator)
	if err != nil && err != .Not_Exist do fmt.panicf("%s: %v", PATH, err)
	defer delete(data)

	if err == nil {
		if json_err := json.unmarshal(data, &settings); json_err != nil do fmt.panicf("%s: %v", PATH, json_err)
	}
	settings.av_offset_ms = clamp(settings.av_offset_ms, -MAX_AV_OFFSET_MS, MAX_AV_OFFSET_MS)
	settings.guitar_gain_tenths = clamp(settings.guitar_gain_tenths, 0, MAX_GAIN_TENTHS)
	settings.song_gain_tenths = clamp(settings.song_gain_tenths, 0, MAX_GAIN_TENTHS)
	settings.guitar_channel = max(settings.guitar_channel, 0)
	settings.pedals = pedals.clamp_knobs(settings.pedals)
	// A constant cannot hold a slice, so the default tuning is set here, and owned like a loaded one.
	if len(settings.tuning) == 0 do settings.tuning = slice.clone(E_STANDARD[:])
	if err == .Not_Exist do save(settings)
	return settings
}

save :: proc(settings: Settings) {
	data, err := json.marshal(settings, {pretty = true})
	if err != nil do fmt.panicf("%s: %v", PATH, err)
	defer delete(data)
	if write_err := os.write_entire_file(PATH, data); write_err != nil do fmt.panicf("%s: %v", PATH, write_err)
}

gain_from_tenths :: proc(tenths: int) -> f32 {
	return f32(tenths) / 10
}
