package main

import "core:fmt"
import "core:slice"
import "core:strings"
import "asio"
import "config"
import "pedals"
import "speakers"
import rl "vendor:raylib"

// The guitar input and the speakers as the settings last asked for them. nil while they are closed, and update_audio then opens them.
Audio :: union {
	Open_Audio,
	Audio_Failure,
}

// The ASIO driver and the channel of the guitar input.
Audio_Setup :: struct {
	driver:  string,
	channel: int,
}

// The guitar input and the speakers while they are open, and what they were opened with, so update_audio sees when settings ask for something else.
Open_Audio :: struct {
	setup: Audio_Setup,
	rig:   string,
	path:  ^Audio_Path,
}

// A setup that did not open, and why. update_audio does not try it again until the setup changes or close_audio forgets it.
Audio_Failure :: struct {
	setup:  Audio_Setup,
	reason: string,
}

// What the two audio threads work with. It stays put on the heap while they run: ASIO hands it to hear_guitar, and the speakers play from it.
Audio_Path :: struct {
	// The clean guitar, for the tuner.
	history:  ^Guitar_History,
	rack:     pedals.Rack,
	// One buffer of the guitar while the rack shapes it, so the buffer of ASIO stays clean.
	toned:    []f32,
	speakers: speakers.Session,
}

// Keeps the guitar input and the speakers in step with the settings of app, once a frame, so the guitar is heard on every screen.
// They are open while the chosen driver is registered and opens, and reopen when the driver or the channel changes.
update_audio :: proc(app: ^App) {
	settings := app.settings
	wanted := Audio_Setup{settings.asio_driver, settings.guitar_channel}
	switch audio in app.audio {
	case nil:
	case Open_Audio:
		if audio.setup != wanted do close_audio(app)
	case Audio_Failure:
		if audio.setup != wanted do close_audio(app)
	}
	if app.audio == nil && slice.contains(app.drivers, wanted.driver) do app.audio = open_audio(settings, &app.history)

	audio, open := &app.audio.(Open_Audio)
	if !open do return
	if audio.rig != settings.rig do change_rig(audio, settings.rig)
	pedals.set_knobs(&audio.path.rack, settings.pedals)
	speakers.set_mix(&audio.path.speakers, speaker_mix(settings))
}

// Opens and starts the guitar input and the speakers that settings ask for, and records the clean guitar into history. Returns them open, or why they did not open.
open_audio :: proc(settings: config.Settings, history: ^Guitar_History) -> Audio {
	setup := Audio_Setup{strings.clone(settings.asio_driver), settings.guitar_channel}
	path := new(Audio_Path)
	path.history = history
	if reason, failed := open_audio_path(path, settings).?; failed {
		free(path)
		fmt.eprintfln("The guitar input did not open: %s", reason)
		return Audio_Failure{setup, strings.clone(reason)}
	}
	return Open_Audio{setup, strings.clone(settings.rig), path}
}

// Opens the guitar input and the speakers into path, and starts them. failure says why they did not open, for the player; then nothing is open.
open_audio_path :: proc(path: ^Audio_Path, settings: config.Settings) -> (failure: Maybe(string)) {
	// ASIO drivers are STA COM objects. Open the driver before the speaker context initializes COM.
	asio.open(settings.asio_driver, settings.guitar_channel, rl.GetWindowHandle(), asio.Listener{hear_guitar, path}) or_return
	defer if failure != nil do asio.close()
	frames := asio.buffer_frames()
	speakers.open(&path.speakers, u32(frames), speaker_mix(settings)) or_return

	path.toned = make([]f32, frames)
	pedals.init(&path.rack, settings.rig, settings.pedals, frames)
	asio.start()
	speakers.start(&path.speakers)
	return nil
}

// Closes the guitar input and the speakers, or forgets why they did not open. Either way update_audio tries the setup again.
close_audio :: proc(app: ^App) {
	switch audio in app.audio {
	case nil:
	case Open_Audio:
		// ASIO closes first: its thread shapes the guitar in the rack and publishes it to the speakers.
		asio.close()
		speakers.close(&audio.path.speakers)
		pedals.destroy(&audio.path.rack)
		delete(audio.path.toned)
		free(audio.path)
		delete(audio.setup.driver)
		delete(audio.rig)
	case Audio_Failure:
		delete(audio.setup.driver)
		delete(audio.reason)
	}
	app.audio = nil
}

// The audio path that a song plays on. A song plays only while the audio is open: the sync menu offers no guitar before,
// and reset_audio leaves the tuner and stops the song before it closes the audio.
song_audio :: proc(app: ^App) -> ^Audio_Path {
	return app.audio.(Open_Audio).path
}

// Plays the guitar of audio through rig, a file name in pedals.RIGS_DIR, from now on.
// The rig loads first, and ASIO, whose thread runs the rack, stops only for the swap, so no buffer plays through a rig that is freed.
change_rig :: proc(audio: ^Open_Audio, rig: string) {
	path := audio.path
	loaded := pedals.load_rig(rig, len(path.toned))
	asio.stop()
	pedals.replace_rig(&path.rack, loaded)
	// The speakers repeat the newest guitar buffer while ASIO stops, so it becomes silence instead. No other thread publishes meanwhile.
	slice.zero(path.toned)
	speakers.publish_guitar(&path.speakers, path.toned)
	asio.start()
	delete(audio.rig)
	audio.rig = strings.clone(rig)
}

// Records the clean guitar for the tuner, shapes it through the rack, and hands it to the speakers. ASIO calls it on its own thread with each buffer.
hear_guitar :: proc(data: rawptr, clean: []f32) {
	path := (^Audio_Path)(data)
	pedals.flush_denormals_on_this_thread()
	record_guitar(path.history, clean)
	copy(path.toned, clean)
	pedals.shape(&path.rack, path.toned)
	speakers.publish_guitar(&path.speakers, path.toned)
}

speaker_mix :: proc(settings: config.Settings) -> speakers.Mix {
	return {
		guitar_gain = config.gain_from_tenths(settings.guitar_gain_tenths),
		song_gain = config.gain_from_tenths(settings.song_gain_tenths),
	}
}

// The loudest sample of the latest guitar buffer after the input knob of settings, where 1 is full scale. 0 while the guitar input is closed.
input_peak :: proc(settings: config.Settings) -> f32 {
	return asio.peak() * pedals.gain_from_db(settings.pedals.input_db)
}
