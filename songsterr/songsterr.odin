// The Songsterr documents of a song, as the cache stores them, and what can be read from them without the network.
package songsterr

import "core:fmt"
import "core:strings"

Song_Info :: struct {
	song_id:              int          `json:"songId"`,
	artist:               string       `json:"artist"`,
	title:                string       `json:"title"`,
	revision_id:          int          `json:"revisionId"`,
	storage_key:          string       `json:"image"`,
	popular_track_guitar: int          `json:"popularTrackGuitar"`,
	tracks:               []Track_Meta `json:"tracks"`,
}

Track_Meta :: struct {
	name:       string `json:"name"`,
	instrument: string `json:"instrument"`,
	hash:       string `json:"hash"`,
	is_empty:   bool   `json:"isEmpty"`,
	// The MIDI note of each open string, from string 0, the high string.
	tuning:     []int  `json:"tuning"`,
}

// A track of Song_Info that is a guitar. index is its position in Song_Info.tracks, and the number of its tab.
Guitar_Track :: struct {
	index:   int,
	name:    string,
	popular: bool,
	tuning:  []int,
}

// The full mix of the song as a YouTube video, and the second at which each bar starts in it.
Full_Mix :: struct {
	video_id:      string,
	measure_times: []f64,
}

Tab :: struct {
	strings:  int       `json:"strings"`,
	frets:    int       `json:"frets"`,
	measures: []Measure `json:"measures"`,
}

Measure :: struct {
	signature:        Maybe([2]int) `json:"signature"`,
	repeat_start:     bool          `json:"repeatStart"`,
	repeat:           int           `json:"repeat"`,
	alternate_ending: []int         `json:"alternateEnding"`,
	voices:           []Voice       `json:"voices"`,
}

Voice :: struct {
	beats: []Beat `json:"beats"`,
}

Beat :: struct {
	duration:     [2]int     `json:"duration"`,
	rest:         bool       `json:"rest"`,
	grace_note:   string     `json:"graceNote"`,
	notes:        []Tab_Note `json:"notes"`,
	vibrato:      bool       `json:"vibrato"`,
	wide_vibrato: bool       `json:"wideVibrato"`,
	// Repick speed as [numerator, denominator] of a whole note. Zero when the beat has none.
	tremolo:      [2]int     `json:"tremolo"`,
	harmonic:     string     `json:"harmonic"`,
}

Bend_Point :: struct {
	position: f64 `json:"position"`,
	tone:     f64 `json:"tone"`,
}

Bend :: struct {
	points: []Bend_Point `json:"points"`,
}

Tab_Note :: struct {
	string_index:      Maybe(int)             `json:"string"`,
	fret:              Maybe(int)             `json:"fret"`,
	tie:               bool                   `json:"tie"`,
	hp:                bool                   `json:"hp"`,
	dead:              bool                   `json:"dead"`,
	vibrato:           bool                   `json:"vibrato"`,
	wide_vibrato:      bool                   `json:"wideVibrato"`,
	left_hand_vibrato: union { bool, string } `json:"leftHandVibrato"`,
	slide:             string                 `json:"slide"`,
	harmonic:          string                 `json:"harmonic"`,
	bend:              Bend                   `json:"bend"`,
	tremolo:           [2]int                 `json:"tremolo"`,
}

// The guitars of the song, in track order. A guitar is a non-empty track whose hash starts with "guitar_".
guitar_tracks :: proc(info: Song_Info) -> []Guitar_Track {
	found: [dynamic]Guitar_Track
	for track, index in info.tracks {
		if track.is_empty || !strings.has_prefix(track.hash, "guitar_") do continue
		append(&found, Guitar_Track{
			index = index,
			name = display_name(track, index),
			popular = index == info.popular_track_guitar,
			tuning = track.tuning,
		})
	}
	return found[:]
}

// "Artist - Title", or whichever of the two the song has.
heading :: proc(info: Song_Info) -> string {
	if info.artist == "" do return info.title
	if info.title == "" do return info.artist
	return fmt.aprintf("%s - %s", info.artist, info.title)
}

// How long [numerator, denominator] of a whole note lasts in quarter notes. A beat's duration and a time signature are both written this way.
quarter_length :: proc(duration: [2]int) -> f64 {
	return 4 * f64(duration[0]) / f64(duration[1])
}

@(private)
display_name :: proc(track: Track_Meta, index: int) -> string {
	if track.name != "" do return track.name
	if track.instrument != "" do return track.instrument
	return fmt.aprintf("Guitar %d", index)
}
