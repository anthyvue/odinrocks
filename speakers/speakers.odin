// The Windows default playback device. It plays the newest buffer of the guitar that another thread publishes, and the song, each at its gain.
package speakers

import "base:runtime"
import "core:fmt"
import "core:sync"
import "../pcm"
import ma "vendor:miniaudio"

// The levels of the guitar and the song, where 1 leaves a level alone.
Mix :: struct {
	guitar_gain: f32,
	song_gain:   f32,
}

// One open playback device. It must stay put while it is open, because the audio callback gets a pointer to it.
Session :: struct {
	audio_context: ma.context_type,
	device:        ma.device,
	guitar_gain:   f32,
	song_gain:     f32,
	// publish_guitar writes into slots[serial & 1] and then counts it in serial. write_mix plays the slot before that, the newest finished one.
	slots:         [2][]f32,
	serial:        u32,
	playing:       bool,
	song_frame:    int,
	song:          [][2]f32,
}

// Opens the speakers with a period of frames, to play with mix. They play no guitar until publish_guitar, and no song until set_song.
// failure says why the device did not open, for the player; then nothing needs closing.
open :: proc(session: ^Session, frames: u32, mix: Mix) -> (failure: Maybe(string)) {
	ma.context_init(nil, 0, nil, &session.audio_context) or_else panic("Failed to initialize audio context")
	defer if failure != nil do ma.context_uninit(&session.audio_context)
	if open_playback_device(session, frames) != .SUCCESS {
		return "the Windows default playback device does not open in exclusive mode, so another app may hold it"
	}
	defer if failure != nil do ma.device_uninit(&session.device)

	if session.device.playback.internalSampleRate != pcm.SAMPLE_RATE || session.device.playback.internalChannels != 2 {
		return fmt.tprintf("the playback device must run at %d Hz in stereo", pcm.SAMPLE_RATE)
	}
	got := session.device.wasapi.actualPeriodSizeInFramesPlayback
	period := session.device.playback.internalPeriodSizeInFrames
	if got != frames || period != frames {
		return fmt.tprintf("the playback period is %d frames and the ASIO buffer is %d, so set the buffer in the interface's control panel to match", max(got, period), frames)
	}

	for &slot in session.slots do slot = make([]f32, frames)
	set_mix(session, mix)
	return nil
}

start :: proc(session: ^Session) {
	ma.device_start(&session.device) or_else panic("Failed to start playback device")
}

// No thread may publish_guitar from now on.
close :: proc(session: ^Session) {
	ma.device_uninit(&session.device)
	ma.context_uninit(&session.audio_context)
	for slot in session.slots do delete(slot)
	session^ = {}
}

// Hands guitar, one period of mono samples, to write_mix, which plays the newest. Only one thread may publish at a time.
// The two devices drift, so write_mix sometimes plays a buffer twice or skips one: that is the tick.
publish_guitar :: proc(session: ^Session, guitar: []f32) {
	serial := sync.atomic_load(&session.serial)
	copy(session.slots[serial & 1], guitar)
	sync.atomic_store(&session.serial, serial + 1)
}

// Plays song from its start, paused, in place of the song before. nil plays none. The song before may be freed once this returns.
set_song :: proc(session: ^Session, song: [][2]f32) {
	// The device stops while the song swaps, so write_mix never reads a song that is freed.
	ma.device_stop(&session.device) or_else panic("Failed to stop playback device")
	session.song = song
	session.song_frame = 0
	session.playing = false
	start(session)
}

// Hands mix to the audio callback, which plays it from its next period.
set_mix :: proc(session: ^Session, mix: Mix) {
	sync.atomic_store(&session.guitar_gain, mix.guitar_gain)
	sync.atomic_store(&session.song_gain, mix.song_gain)
}

// The song moves on only while it plays. The guitar is heard either way.
set_playing :: proc(session: ^Session, on: bool) {
	sync.atomic_store(&session.playing, on)
}

// The next frame of the song that the speakers get. It is the clock of the song.
song_frame :: proc(session: ^Session) -> int {
	return sync.atomic_load(&session.song_frame)
}

song_frame_count :: proc(session: ^Session) -> int {
	return len(session.song)
}

seconds_from :: proc(frame: int) -> f64 {
	return f64(frame) / pcm.SAMPLE_RATE
}

seek :: proc(session: ^Session, frame: int) {
	sync.atomic_store(&session.song_frame, clamp(frame, 0, song_frame_count(session)))
}

// The newest guitar buffer that publish_guitar finished, or nil before the first.
@(private)
latest_guitar :: proc(session: ^Session) -> []f32 {
	serial := sync.atomic_load(&session.serial)
	if serial == 0 do return nil
	return session.slots[(serial - 1) & 1]
}

// Opens the Windows default playback device. It stays on that device even when the default changes, because a new device could have another period.
@(private)
open_playback_device :: proc(session: ^Session, frames: u32) -> ma.result {
	device_config := ma.device_config_init(.playback)
	device_config.playback.format = .f32
	device_config.playback.channels = 2
	device_config.playback.shareMode = .exclusive
	device_config.wasapi.noAutoStreamRouting = true
	device_config.sampleRate = pcm.SAMPLE_RATE
	device_config.periodSizeInFrames = frames
	device_config.periods = 1
	device_config.dataCallback = write_mix
	device_config.pUserData = session
	return ma.device_init(&session.audio_context, &device_config, &session.device)
}

@(private)
write_mix :: proc "c" (device: ^ma.device, output, _: rawptr, frame_count: u32) {
	context = runtime.default_context()
	session := (^Session)(device.pUserData)
	guitar := latest_guitar(session)
	if len(guitar) == 0 do return

	guitar_gain := sync.atomic_load(&session.guitar_gain)
	pairs := ([^][2]f32)(output)[:int(frame_count)]
	for &pair, frame in pairs do pair = guitar[frame] * guitar_gain

	if !sync.atomic_load(&session.playing) do return

	song_gain := sync.atomic_load(&session.song_gain)
	cursor := sync.atomic_load(&session.song_frame)
	mixed := 0
	for &pair, frame in pairs {
		index := cursor + frame
		if index >= len(session.song) do break
		pair += session.song[index] * song_gain
		mixed += 1
	}
	// A seek can store song_frame while this period mixes. Only publish the advance if the cursor is still the one this period started from.
	if mixed > 0 do sync.atomic_compare_exchange_strong(&session.song_frame, cursor, cursor + mixed)
}
