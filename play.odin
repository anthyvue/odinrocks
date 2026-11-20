package main

import "core:fmt"
import vmem "core:mem/virtual"
import "asio"
import "chart"
import "config"
import "menu"
import "pedals"
import "render"
import "songcache"
import "songsterr"
import "speakers"
import "ui"
import "wav"
import rl "vendor:raylib"

// One guitar of a song, ready to play.
Song :: struct {
	full_mix:      [][2]f32,
	measure_times: []f64,
	gems:          []chart.Gem,
	positions:     []chart.Hand_Position,
	string_count:  int,
}

// Loads guitar of back.sync into song_arena, hands its recording to the speakers of path, which the guitar already plays through, and sets the drop of its rack to drop_semitones.
// The song opens paused, so the player starts it when ready.
start_song :: proc(song_arena: ^vmem.Arena, path: ^Audio_Path, back: Sync_Screen, guitar: songsterr.Guitar_Track, drop_semitones: int) -> Play_Screen {
	context.allocator = vmem.arena_allocator(song_arena)
	song := load_song(back.sync, guitar.index)
	speakers.set_song(&path.speakers, song.full_mix)
	pedals.set_drop(&path.rack, drop_semitones)
	rl.SetWindowTitle(fmt.ctprint(back.sync.heading))
	return {back = back, song = song, overlay = .Pause}
}

// Reads guitar track of sync from the cache, places its gems and the hand, and decodes the recording. Placing takes milliseconds, so the cache does not keep it.
load_song :: proc(sync: songcache.Cached_Sync, track: int) -> Song {
	tab := songcache.read_tab(sync.dir, track)
	measure_times := songcache.read_measure_times(sync.dir, sync.mode, track)
	played := chart.played_measures(tab.measures, measure_times)
	gems := chart.place_gems(played, tab.frets, measure_times)
	mix_wav := songcache.full_mix_wav(sync.dir)
	return {
		full_mix      = wav.decode(mix_wav) or_else fmt.panicf("%s cannot be played", mix_wav),
		measure_times = measure_times,
		gems          = gems,
		positions     = chart.hand_positions(gems),
		string_count  = tab.strings,
	}
}

// Takes the song that start_song started from the speakers of path, turns the drop off, and frees song_arena.
stop_song :: proc(song_arena: ^vmem.Arena, path: ^Audio_Path) {
	// write_mix reads the full mix in song_arena until the speakers let go of it.
	speakers.set_song(&path.speakers, nil)
	pedals.set_drop(&path.rack, 0)
	vmem.arena_free_all(song_arena)
	rl.SetWindowTitle("odinrocks")
}

// Draws one frame of the play screen, which plays on output, and applies the input of that frame to play and settings. rigs are the rigs the tone editor offers.
// Returns false when the player quits the song.
play_frame :: proc(play: ^Play_Screen, output: ^speakers.Session, settings: ^config.Settings, rigs: []string) -> (keep_playing: bool) {
	// The song waits while the player scrubs, so the audio callback leaves the song cursor to the mouse.
	play.scrubbing = play.overlay == .None && is_scrubbing(play.scrubbing)
	speakers.set_playing(output, play.overlay == .None && !play.scrubbing)
	draw_song(play, output, settings^)

	// Each overlay reads only its own input. A new overlay shows from the next frame, so it does not see the key or click that opened it.
	switch play.overlay {
	case .None:
		apply_guitar_gain_keys(settings)
		apply_av_offset_keys(settings)
		if play.scrubbing do speakers.seek(output, render.frame_at_mouse(speakers.song_frame_count(output)))
		if ui.is_back_pressed() do play.overlay = .Pause
	case .Pause:
		switch _ in menu.show_pause_menu() {
		case nil:
		case menu.Resume:
			play.overlay = .None
		case menu.Open_Tone:
			play.overlay = .Tone
		case menu.Restart:
			speakers.seek(output, 0)
			play.overlay = .None
		case menu.Quit_Song:
			return false
		}
	case .Tone:
		if menu.show_tone_overlay(settings, rigs, input_peak(settings^)) do play.overlay = .Pause
	}
	return true
}

// Draws the highway and the HUD at the playhead of output, and moves the camera of play.
draw_song :: proc(play: ^Play_Screen, output: ^speakers.Session, settings: config.Settings) {
	song_frame := speakers.song_frame(output)
	now := playhead(song_frame, settings.av_offset_ms)
	guitar_gain := config.gain_from_tenths(settings.guitar_gain_tenths)
	song := play.song

	rl.ClearBackground(render.HIGHWAY_BACKGROUND)
	render.draw_highway(&play.camera, now, song.gems, song.positions, song.measure_times, song.string_count)
	render.draw_song_progress(song_frame, speakers.song_frame_count(output))
	render.draw_status(speakers.seconds_from(song_frame), guitar_gain, settings.av_offset_ms, asio.peak())
	if settings.draw_hit_flash do render.draw_hit_flash(now, song.gems)
}

// Up raises the guitar gain by a tenth and Down lowers it, inside the range the settings screen allows.
apply_guitar_gain_keys :: proc(settings: ^config.Settings) {
	step: int
	if rl.IsKeyPressed(.UP) do step = 1
	else if rl.IsKeyPressed(.DOWN) do step = -1
	settings.guitar_gain_tenths = clamp(settings.guitar_gain_tenths + step, 0, config.MAX_GAIN_TENTHS)
}

// ] moves the A/V offset 10 ms later and [ 10 ms earlier, or 50 ms with Shift, inside the range the settings screen allows.
apply_av_offset_keys :: proc(settings: ^config.Settings) {
	direction: int
	if rl.IsKeyPressed(.RIGHT_BRACKET) do direction = 1
	else if rl.IsKeyPressed(.LEFT_BRACKET) do direction = -1
	size := 50 if rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT) else 10
	settings.av_offset_ms = clamp(settings.av_offset_ms + direction * size, -config.MAX_AV_OFFSET_MS, config.MAX_AV_OFFSET_MS)
}

// The player scrubs while the left button is held, from when it is down on the progress bar.
is_scrubbing :: proc(was_scrubbing: bool) -> bool {
	return rl.IsMouseButtonDown(.LEFT) && (was_scrubbing || render.is_mouse_on_progress_bar())
}

// The gem clock in seconds. song_frame moves when a buffer is handed to the speakers, before it is heard, so a positive offset delays the gems.
playhead :: proc(song_frame, av_offset_ms: int) -> f64 {
	return speakers.seconds_from(song_frame) - f64(av_offset_ms) / 1000
}
