package main

import "core:fmt"
import vmem "core:mem/virtual"
import "core:thread"
import "chart"
import "fetch"
import "menu"
import "songcache"
import "songsterr"
import "songsync"
import "wav"
import "youtube"

// Which step of preparing a song failed. The details are on the console.
Prepare_Error :: enum {
	None,
	Song_Unavailable,
	Tab_Unavailable,
	No_Full_Mix,
	No_Guitars,
	Unreadable_Tab,
	Recording_Failed,
}

@(rodata)
PREPARE_ERROR_TEXT := #partial [Prepare_Error]string {
	.Song_Unavailable = "Could not load this song from Songsterr. Check the id and the connection.",
	.Tab_Unavailable  = "Could not load a guitar tab from Songsterr. Check the connection.",
	.No_Full_Mix      = "Songsterr has no full-mix recording for this song.",
	.No_Guitars       = "This song has no guitar tracks.",
	.Unreadable_Tab   = "A guitar tab of this song cannot be read. The console shows why.",
	.Recording_Failed = "Could not download the recording. The console shows why.",
}

// The message the library shows for err. nil when nothing failed.
prepare_error_text :: proc(err: Prepare_Error) -> Maybe(string) {
	if err == .None do return nil
	return PREPARE_ERROR_TEXT[err]
}

// What the download thread reads and writes. It is on the heap, so it stays put while the union copies Download_Screen.
Download_Job :: struct {
	request: menu.Download,
	// The thread writes it. Read it only after the thread is done.
	err:     Prepare_Error,
}

// Runs prepare_song for request on a new thread.
start_download :: proc(request: menu.Download) -> Download_Screen {
	job := new_clone(Download_Job{request = request})
	// No init_context, so the thread gets a default context: the tracking allocator of a debug build is not thread-safe.
	worker := thread.create_and_start_with_poly_data(job, run_download)
	return {job = job, worker = worker}
}

// The body of the download thread. It touches nothing but job, the cache, and the console.
run_download :: proc(job: ^Download_Job) {
	job.err = prepare_song(job.request.song_id, job.request.mode, job.request.redownload)
}

// Waits for the thread of download to end, frees it and its job, and returns what failed.
finish_download :: proc(download: Download_Screen) -> Prepare_Error {
	thread.destroy(download.worker)
	err := download.job.err
	free(download.job)
	return err
}

// Makes every guitar of song_id playable in mode. Downloads the source when the cache lacks it or redownload asks for it.
// Basic plays from the source alone. Advanced also needs the synced times of every guitar.
prepare_song :: proc(song_id: int, mode: songcache.Sync_Mode, redownload: bool) -> Prepare_Error {
	arena: vmem.Arena
	defer vmem.arena_destroy(&arena)
	context.allocator = vmem.arena_allocator(&arena)

	dir, cached := songcache.find_complete_source(song_id)
	if !cached || redownload do dir = download_source_into_cache(song_id) or_return
	if mode == .Advanced do return sync_guitars(dir)
	return .None
}

// Moves the measure times of every guitar of the song in dir onto the attacks of its recording, and saves them. Keeps the times the cache already has.
sync_guitars :: proc(dir: string) -> Prepare_Error {
	guitars := songsterr.guitar_tracks(songcache.read_song_info(dir))
	pending: [dynamic]int
	for part in guitars {
		if songcache.has_synced_times(dir, part.index) do fmt.printfln("reused guitar %d", part.index)
		else do append(&pending, part.index)
	}
	if len(pending) == 0 do return .None

	full_mix_times := songcache.read_full_mix(dir).measure_times
	frames, frames_ok := wav.decode(songcache.full_mix_wav(dir))
	if !frames_ok do return .Recording_Failed
	attacks := songsync.measure_attacks(frames)
	for track in pending {
		tab := songcache.read_tab(dir, track)
		played := chart.played_measures(tab.measures, full_mix_times)
		synced := songsync.sync_automatically(played, full_mix_times, attacks, tab.frets)
		songcache.save_synced_times(dir, track, synced)
	}
	return .None
}

// Fetches the song info, the full mix times, every guitar tab, and the full mix audio into a new source/ in the cache. Returns the song directory.
// Everything but the audio is fetched before reset_source, so a song that cannot be fetched cannot wipe a good cache.
download_source_into_cache :: proc(song_id: int) -> (dir: string, err: Prepare_Error) {
	info, info_ok := fetch.song_info(song_id)
	if !info_ok do return "", .Song_Unavailable
	fmt.printfln("%s, revision %d", songsterr.heading(info), info.revision_id)
	full_mix, full_mix_ok := fetch.full_mix(info)
	if !full_mix_ok do return "", .No_Full_Mix
	guitars := songsterr.guitar_tracks(info)
	if len(guitars) == 0 do return "", .No_Guitars

	tabs := make([]songsterr.Tab, len(guitars))
	for part, index in guitars {
		tab, tab_ok := fetch.tab(info, part.index)
		if !tab_ok do return "", .Tab_Unavailable
		if !chart.check_tab(tab, full_mix.measure_times) {
			fmt.eprintfln("guitar %d cannot be read", part.index)
			return "", .Unreadable_Tab
		}
		if len(part.tuning) != tab.strings {
			fmt.eprintfln("guitar %d has %d strings and a tuning of %d", part.index, tab.strings, len(part.tuning))
			return "", .Unreadable_Tab
		}
		tabs[index] = tab
	}

	dir = songcache.reset_source(info, full_mix)
	for part, index in guitars do songcache.save_tab(dir, part.index, tabs[index])
	recording_wav := songcache.full_mix_wav(dir)
	if !youtube.download_full_mix(full_mix.video_id, recording_wav) do return "", .Recording_Failed
	return dir, .None
}
