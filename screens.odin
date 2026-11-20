package main

import vmem "core:mem/virtual"
import "core:thread"
import "config"
import "menu"
import "render"
import "songcache"
import "songsterr"

// The state that outlives a visit to one screen. main owns it for the whole run. It stays put, because the audio threads and the arenas point into it.
App :: struct {
	settings:       config.Settings,
	library:        menu.Library,
	// What the last download failed at. The library shows it until the player opens a sync or downloads again.
	download_error: Prepare_Error,
	// Each list is read again after the cache or the registry may have changed. Its arena holds only that list.
	syncs:          []songcache.Cached_Sync,
	syncs_arena:    vmem.Arena,
	drivers:        []string,
	drivers_arena:  vmem.Arena,
	// Holds the song that Play_Screen plays. The union copies its variants, so it lives here.
	song_arena:     vmem.Arena,
	audio:          Audio,
	history:        Guitar_History,
	// The file names of the rigs in pedals.RIGS_DIR, from clean to lead.
	rigs:           []string,
}

// The screen the main loop shows. Each variant holds the state of one visit to its screen.
Screen :: union #no_nil {
	Library_Screen,
	Missing_Tools_Screen,
	Download_Screen,
	Sync_Screen,
	Play_Screen,
	Tuner_Screen,
	Tone_Screen,
	Settings_Screen,
}

Library_Screen :: struct {}

// Shown instead of every other screen when a required program is not on PATH. The app cannot leave it.
Missing_Tools_Screen :: struct {
	names: []string,
}

// A download that runs on its own thread, so the window keeps drawing. It returns to the library when the thread ends.
Download_Screen :: struct {
	job:    ^Download_Job,
	worker: ^thread.Thread,
}

// The menu of one song in one sync mode.
Sync_Screen :: struct {
	sync:   songcache.Cached_Sync,
	scroll: int,
}

// One guitar of a song that plays. back is the menu that the song returns to.
Play_Screen :: struct {
	back:      Sync_Screen,
	song:      Song,
	overlay:   Overlay,
	// The player holds the progress bar, and the song follows the mouse.
	scrubbing: bool,
	camera:    render.Camera,
}

// What the play screen shows over the highway. The song plays only under None.
Overlay :: enum {
	None,
	Pause,
	// The tone editor, opened from the pause menu.
	Tone,
}

// The open strings of a guitar of the song, tuned one at a time from the guitar input before the guitar plays in a tuning other than the player's.
// back is the menu that the tuner returns to, and that the song returns to.
Tuner_Screen :: struct {
	back:         Sync_Screen,
	guitar:       songsterr.Guitar_Track,
	// The string being tuned, as an index into guitar.tuning.
	string_index: int,
	// How many cents the needle shows the string above its note. nil until a note is heard on this string.
	needle:       Maybe(f32),
}

Settings_Screen :: struct {}

// The tone editor, reached from the settings screen, which it returns to.
Tone_Screen :: struct {}
