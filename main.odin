package main

import "core:fmt"
import "core:mem"
import vmem "core:mem/virtual"
import "core:slice"
import "core:strings"
import "core:thread"
import "asio"
import "config"
import "menu"
import "pedals"
import "songcache"
import "youtube"
import rl "vendor:raylib"

// vendor:curl excludes the dynamic C runtime and the static raylib excludes the static one, which leaves none.
// raylib needs the dynamic one, so it is named here, where both are linked.
@(require)
foreign import crt "system:msvcrt.lib"

// The window size when it is not borderless, and the smallest size it can be resized to.
WINDOW_WIDTH :: 1280
WINDOW_HEIGHT :: 720

main :: proc() {
	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		context.allocator = mem.tracking_allocator(&track)
		defer mem.tracking_allocator_destroy(&track)
		defer report_leaks(&track)
	}

	app := App{settings = config.load()}
	defer delete(app.settings.asio_driver)
	defer delete(app.settings.rig)
	defer delete(app.settings.tuning)
	// Covers F11 on the menus and a window closed on the settings screen.
	defer config.save(app.settings)

	app.rigs = pedals.list_rigs()
	defer {
		for rig in app.rigs do delete(rig)
		delete(app.rigs)
	}
	if !slice.contains(app.rigs, app.settings.rig) {
		delete(app.settings.rig)
		app.settings.rig = strings.clone(pedals.DEFAULT_RIG)
	}

	// No WINDOW_HIGHDPI: GLFW makes the process DPI aware on Windows, so a screen unit is already a physical pixel.
	rl.SetConfigFlags({.WINDOW_RESIZABLE, .MSAA_4X_HINT})
	rl.InitWindow(WINDOW_WIDTH, WINDOW_HEIGHT, "odinrocks")
	defer rl.CloseWindow()
	rl.SetWindowMinSize(WINDOW_WIDTH, WINDOW_HEIGHT)
	rl.SetTargetFPS(240)
	rl.SetExitKey(.KEY_NULL)

	defer strings.builder_destroy(&app.library.song_id)
	defer vmem.arena_destroy(&app.syncs_arena)
	defer vmem.arena_destroy(&app.drivers_arena)
	defer vmem.arena_destroy(&app.song_arena)
	refresh_syncs(&app)
	refresh_drivers(&app)

	missing_tools := youtube.missing_tools()
	defer delete(missing_tools)
	screen: Screen = Library_Screen{}
	if len(missing_tools) > 0 do screen = Missing_Tools_Screen{names = missing_tools}

	for !rl.WindowShouldClose() {
		defer free_all(context.temp_allocator)
		if asio.reset_requested() do reset_audio(&app, &screen)
		if rl.IsKeyPressed(.F11) do app.settings.borderless = !app.settings.borderless
		apply_window_mode(app.settings.borderless)
		rl.BeginDrawing()
		quit := show_screen(&app, &screen)
		rl.EndDrawing()
		if quit do break
		update_audio(&app)
	}
	end_screen(&app, screen)
	close_audio(&app)
}

// Draws one frame of screen and applies the input of that frame. Replaces screen when the player leaves it. quit is true when the player quits the game.
// The new screen draws from the next frame, after EndDrawing has read new input, so it does not see the key or click that opened it.
// Assign screen last in a case: the assignment replaces the state that current points to.
show_screen :: proc(app: ^App, screen: ^Screen) -> (quit: bool) {
	switch &current in screen^ {
	case Library_Screen:
		download_error_text := prepare_error_text(app.download_error)
		switch action in menu.show_library(&app.library, app.syncs, download_error_text) {
		case nil:
		case menu.Open_Settings:
			refresh_drivers(app)
			// The player may have plugged the interface in since, so update_audio tries the setup again.
			if _, failed := app.audio.(Audio_Failure); failed do close_audio(app)
			screen^ = Settings_Screen{}
		case menu.Download:
			screen^ = start_download(action)
		case menu.Open_Sync:
			app.download_error = .None
			screen^ = Sync_Screen{sync = action.sync}
		}
	case Missing_Tools_Screen:
		menu.draw_missing_tools(current.names)
	case Download_Screen:
		menu.draw_downloading(current.job.request)
		if thread.is_done(current.worker) {
			app.download_error = finish_download(current)
			refresh_syncs(app)
			screen^ = Library_Screen{}
		}
	case Sync_Screen:
		_, audio_open := app.audio.(Open_Audio)
		switch action in menu.show_sync_menu(current.sync, &current.scroll, audio_open) {
		case nil:
		case menu.Close_Sync_Menu:
			screen^ = Library_Screen{}
		case menu.Delete_Sync:
			context.allocator = context.temp_allocator
			songcache.remove_sync(current.sync.dir, current.sync.mode)
			refresh_syncs(app)
			screen^ = Library_Screen{}
		case menu.Play_Guitar:
			// start_song and start_tuner read current, so the new screen is built apart before it replaces current.
			if slice.equal(action.guitar.tuning, app.settings.tuning) {
				play := start_song(&app.song_arena, song_audio(app), current, action.guitar, 0)
				screen^ = play
			} else {
				tuner := start_tuner(current, action.guitar)
				screen^ = tuner
			}
		}
	case Play_Screen:
		path := song_audio(app)
		if !play_frame(&current, &path.speakers, &app.settings, app.rigs) {
			back := current.back
			stop_song(&app.song_arena, path)
			config.save(app.settings)
			screen^ = back
		}
	case Tuner_Screen:
		switch action in tune_frame(&current, &app.history, app.settings.tuning) {
		case nil:
		case menu.Close_Tuner:
			back := current.back
			screen^ = back
		case menu.Play_Tuned:
			delete(app.settings.tuning)
			app.settings.tuning = slice.clone(current.guitar.tuning)
			play := start_song(&app.song_arena, song_audio(app), current.back, current.guitar, 0)
			screen^ = play
		case menu.Play_With_Drop:
			play := start_song(&app.song_arena, song_audio(app), current.back, current.guitar, action.semitones)
			screen^ = play
		}
	case Tone_Screen:
		if menu.show_tone(&app.settings, app.rigs, input_peak(app.settings)) {
			config.save(app.settings)
			screen^ = Settings_Screen{}
		}
	case Settings_Screen:
		failure: Maybe(string)
		if failed, ok := app.audio.(Audio_Failure); ok do failure = failed.reason
		switch _ in menu.edit_settings(&app.settings, app.drivers, failure) {
		case nil:
		case menu.Close_Settings:
			config.save(app.settings)
			screen^ = Library_Screen{}
		case menu.Open_Tone:
			screen^ = Tone_Screen{}
		case menu.Quit_Game:
			quit = true
		}
	}
	return
}

// The ASIO driver asked for a reset. Closes the guitar input and the speakers, which update_audio opens again at the end of the frame.
// A song stops first. The song and the tuner return to their menu: the speakers reopen without the song, and the tuner can start a song on audio that may not reopen.
reset_audio :: proc(app: ^App, screen: ^Screen) {
	fmt.eprintln("The ASIO driver asked for a reset, so the guitar input reopens.")
	#partial switch current in screen^ {
	case Play_Screen:
		stop_song(&app.song_arena, song_audio(app))
		screen^ = current.back
	case Tuner_Screen:
		screen^ = current.back
	}
	close_audio(app)
}

// Ends the work that screen still runs when the window closes.
end_screen :: proc(app: ^App, screen: Screen) {
	switch current in screen {
	case Play_Screen:
		stop_song(&app.song_arena, song_audio(app))
	case Download_Screen:
		fmt.println("Waiting for the download to finish.")
		finish_download(current)
	case Library_Screen, Missing_Tools_Screen, Sync_Screen, Tuner_Screen, Tone_Screen, Settings_Screen:
	}
}

refresh_syncs :: proc(app: ^App) {
	vmem.arena_free_all(&app.syncs_arena)
	context.allocator = vmem.arena_allocator(&app.syncs_arena)
	app.syncs = songcache.list_cached()
}

refresh_drivers :: proc(app: ^App) {
	vmem.arena_free_all(&app.drivers_arena)
	context.allocator = vmem.arena_allocator(&app.drivers_arena)
	app.drivers = asio.list_drivers()
}

// The main loop calls it every frame, so an edit of the setting takes effect at once.
apply_window_mode :: proc(borderless: bool) {
	if rl.IsWindowState({.BORDERLESS_WINDOWED_MODE}) == borderless do return
	// The toggle restores the size and place the window had before it went borderless.
	rl.ToggleBorderlessWindowed()
	if !borderless do return
	// Windows and the GPU driver treat a window that covers the monitor exactly as exclusive fullscreen,
	// and switching in and out of it stalls for seconds. 2 more rows, below the monitor edge, prevent that, as in Godot.
	monitor := rl.GetCurrentMonitor()
	rl.SetWindowSize(rl.GetMonitorWidth(monitor), rl.GetMonitorHeight(monitor) + 2)
}

report_leaks :: proc(track: ^mem.Tracking_Allocator) {
	for _, leak in track.allocation_map do fmt.eprintfln("%v leaked %m", leak.location, leak.size)
}
