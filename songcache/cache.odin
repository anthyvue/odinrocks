// Finds, reads, and saves the files of the song cache. The procedures also leave their paths and file contents in context.allocator, so callers set it to an arena.
package songcache

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "../songsterr"

// cache/{id}-{artist}-{title}/
//   source/          song.json  full_mix.json  full_mix.wav  tracks/{index}.json
//   sync_advanced/   {index}.json, the measure times of each guitar that Advanced moved onto the recording
CACHE_DIR :: "cache"
SOURCE_DIR :: "source"
TRACKS_DIR :: "tracks"
SYNC_DIR :: "sync_advanced"
SONG_FILE :: "song.json"
FULL_MIX_FILE :: "full_mix.json"
FULL_MIX_WAV :: "full_mix.wav"

// Where the measure times of a guitar come from. Basic plays the full-mix video points as they are, so every guitar of a complete source plays in it.
// Advanced plays the times that a download moved onto the attacks of the recording.
Sync_Mode :: enum {
	Basic,
	Advanced,
}

@(rodata)
SOURCE_FILES := [?]string{SONG_FILE, FULL_MIX_FILE, FULL_MIX_WAV}

// One song in one sync mode. guitars are the ones that play in it, the most played first.
Cached_Sync :: struct {
	dir:     string,
	song_id: int,
	heading: string,
	mode:    Sync_Mode,
	guitars: []songsterr.Guitar_Track,
}

// Lists one sync per song and mode that has at least one guitar, ordered by song id, then mode.
list_cached :: proc() -> []Cached_Sync {
	syncs: [dynamic]Cached_Sync
	for song_id, dir in song_dirs() {
		if !source_complete(dir) do continue
		info := read_song_info(dir)
		heading := songsterr.heading(info)
		guitars := songsterr.guitar_tracks(info)
		slice.stable_sort_by(guitars, proc(left, right: songsterr.Guitar_Track) -> bool { return left.popular && !right.popular })
		append(&syncs, Cached_Sync{dir = dir, song_id = song_id, heading = heading, mode = .Basic, guitars = guitars})
		synced: [dynamic]songsterr.Guitar_Track
		for part in guitars do if has_synced_times(dir, part.index) do append(&synced, part)
		if len(synced) > 0 do append(&syncs, Cached_Sync{dir = dir, song_id = song_id, heading = heading, mode = .Advanced, guitars = synced[:]})
	}
	slice.sort_by(syncs[:], proc(left, right: Cached_Sync) -> bool {
		if left.song_id != right.song_id do return left.song_id < right.song_id
		return left.mode < right.mode
	})
	return syncs[:]
}

find_complete_source :: proc(song_id: int) -> (dir: string, found: bool) {
	dir = find_song_dir(song_id) or_return
	return dir, source_complete(dir)
}

// Empties source/ of the song and writes the song info and the full mix times into it. Returns the song directory.
// The synced times belong to the old source, so they go too.
reset_source :: proc(info: songsterr.Song_Info, full_mix: songsterr.Full_Mix) -> (dir: string) {
	dir = find_song_dir(info.song_id) or_else new_song_dir(info)
	source_dir := join(dir, SOURCE_DIR)
	remove_dir(source_dir)
	remove_dir(join(dir, SYNC_DIR))
	make_dir(join(source_dir, TRACKS_DIR))
	write_json(join(source_dir, SONG_FILE), info)
	write_json(join(source_dir, FULL_MIX_FILE), full_mix)
	return
}

save_tab :: proc(dir: string, track: int, tab: songsterr.Tab) {
	write_json(tab_path(dir, track), tab)
}

// Deletes what the sync of dir in mode plays from: the whole song for Basic, which needs only the source, and the synced times for Advanced.
remove_sync :: proc(dir: string, mode: Sync_Mode) {
	switch mode {
	case .Basic:
		remove_dir(dir)
	case .Advanced:
		remove_dir(join(dir, SYNC_DIR))
	}
}

save_synced_times :: proc(dir: string, track: int, measure_times: []f64) {
	make_dir(join(dir, SYNC_DIR))
	write_json(synced_times_path(dir, track), measure_times)
}

has_synced_times :: proc(dir: string, track: int) -> bool {
	return os.exists(synced_times_path(dir, track))
}

// The second at which each bar of the guitar track starts in the recording, in mode.
read_measure_times :: proc(dir: string, mode: Sync_Mode, track: int) -> []f64 {
	switch mode {
	case .Basic:
		return read_full_mix(dir).measure_times
	case .Advanced:
		return read_json(synced_times_path(dir, track), []f64)
	}
	unreachable()
}

full_mix_wav :: proc(dir: string) -> string {
	return join(dir, SOURCE_DIR, FULL_MIX_WAV)
}

read_song_info :: proc(dir: string) -> songsterr.Song_Info {
	return read_json(join(dir, SOURCE_DIR, SONG_FILE), songsterr.Song_Info)
}

read_full_mix :: proc(dir: string) -> songsterr.Full_Mix {
	return read_json(join(dir, SOURCE_DIR, FULL_MIX_FILE), songsterr.Full_Mix)
}

read_tab :: proc(dir: string, track: int) -> songsterr.Tab {
	return read_json(tab_path(dir, track), songsterr.Tab)
}

@(private)
source_complete :: proc(dir: string) -> bool {
	if !files_exist(join(dir, SOURCE_DIR), SOURCE_FILES[:]) do return false
	guitars := songsterr.guitar_tracks(read_song_info(dir))
	for part in guitars do if !os.exists(tab_path(dir, part.index)) do return false
	return true
}

@(private)
files_exist :: proc(dir: string, names: []string) -> bool {
	for name in names do if !os.exists(join(dir, name)) do return false
	return true
}

@(private)
tab_path :: proc(dir: string, track: int) -> string {
	return join(dir, SOURCE_DIR, TRACKS_DIR, fmt.aprintf("%d.json", track))
}

@(private)
synced_times_path :: proc(dir: string, track: int) -> string {
	return join(dir, SYNC_DIR, fmt.aprintf("%d.json", track))
}

@(private)
find_song_dir :: proc(song_id: int) -> (dir: string, found: bool) {
	dirs := song_dirs()
	dir, found = dirs[song_id]
	return
}

// Maps the id of every cache/{id}-... folder to its path. Panics when two folders have the same id.
@(private)
song_dirs :: proc() -> (dirs: map[int]string) {
	infos, err := os.read_all_directory_by_path(CACHE_DIR, context.allocator)
	if err == .Not_Exist do return
	if err != nil do fmt.panicf("%s: %v", CACHE_DIR, err)
	for info in infos {
		if info.type != .Directory do continue
		id_text, dash, _ := strings.partition(info.name, "-")
		if dash == "" do continue
		song_id := strconv.parse_int(id_text) or_continue
		if song_id in dirs do fmt.panicf("more than one cache directory for song %d", song_id)
		dirs[song_id] = info.fullpath
	}
	return
}

@(private)
new_song_dir :: proc(info: songsterr.Song_Info) -> string {
	return join(CACHE_DIR, fmt.aprintf("%d-%s-%s", info.song_id, safe_label(info.artist), safe_label(info.title)))
}

@(private)
safe_label :: proc(text: string) -> string {
	b := strings.builder_make()
	for r in text {
		switch r {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', ' ', '-', '_':
			strings.write_rune(&b, r)
		}
	}
	label := strings.trim_right(strings.to_string(b), " ")
	return label if label != "" else "song"
}

// Panics when the path cannot be allocated, like every other cache step that fails.
@(private)
join :: proc(parts: ..string) -> string {
	return filepath.join(parts) or_else panic("path")
}

@(private)
make_dir :: proc(path: string) {
	if err := os.make_directory_all(path); err != nil do fmt.panicf("%s: %v", path, err)
}

@(private)
remove_dir :: proc(path: string) {
	if !os.exists(path) do return
	if err := os.remove_all(path); err != nil do fmt.panicf("%s: %v", path, err)
}

@(private)
read_json :: proc(path: string, $T: typeid) -> (value: T) {
	data, read_err := os.read_entire_file(path, context.allocator)
	if read_err != nil do fmt.panicf("%s: %v", path, read_err)
	if err := json.unmarshal(data, &value); err != nil do fmt.panicf("%s: %v", path, err)
	return
}

@(private)
write_json :: proc(path: string, value: any) {
	data, err := json.marshal(value)
	if err != nil do fmt.panicf("%s: %v", path, err)
	if write_err := os.write_entire_file(path, data); write_err != nil do fmt.panicf("%s: %v", path, write_err)
}
