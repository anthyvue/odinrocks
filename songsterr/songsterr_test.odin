package songsterr

import "core:encoding/json"
import "core:testing"

@(test)
guitar_tracks_keeps_guitar_hashes :: proc(t: ^testing.T) {
	info := Song_Info{
		title = "Pardon Me",
		popular_track_guitar = 2,
		tracks = []Track_Meta{
			{name = "Brandon Boyd (Vocals)", hash = "vocals_WQHeHibz"},
			{name = "Mike Einziger", instrument = "Electric Guitar (clean)", hash = "guitar_hTITHj9N"},
			{name = "Mike Einziger (Sound Effects)", instrument = "Electric Guitar (clean)", hash = "guitar_Xw51QDhO"},
			{name = "Empty Guitar", hash = "guitar_empty", is_empty = true},
			{name = "Alex Katunich (Bass)", hash = "bass_t03WhkMK"},
			{name = "Jose Pasillas (Drums)", hash = "drums_SbK8EhQT"},
		},
	}
	tracks := guitar_tracks(info)
	defer delete(tracks)
	testing.expect_value(t, len(tracks), 2)
	testing.expect_value(t, tracks[0].index, 1)
	testing.expect_value(t, tracks[0].name, "Mike Einziger")
	testing.expect(t, !tracks[0].popular)
	testing.expect_value(t, tracks[1].index, 2)
	testing.expect_value(t, tracks[1].name, "Mike Einziger (Sound Effects)")
	testing.expect(t, tracks[1].popular)
}

@(test)
guitar_tracks_name_falls_back_to_instrument_then_number :: proc(t: ^testing.T) {
	info := Song_Info{
		tracks = []Track_Meta{
			{instrument = "Acoustic Guitar (steel)", hash = "guitar_a"},
			{hash = "guitar_b"},
		},
	}
	tracks := guitar_tracks(info)
	defer delete(tracks)
	defer delete(tracks[1].name)
	testing.expect_value(t, tracks[0].name, "Acoustic Guitar (steel)")
	testing.expect_value(t, tracks[1].name, "Guitar 1")
}

@(test)
left_hand_vibrato_is_false_or_a_strength_word :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	body := `{"measures":[{"voices":[{"beats":[{"notes":[{"leftHandVibrato":false},{"leftHandVibrato":"slight"},{"leftHandVibrato":"wide"}]}]}]}]}`
	tab: Tab
	testing.expect(t, json.unmarshal_string(body, &tab) == nil)
	notes := tab.measures[0].voices[0].beats[0].notes
	_, is_word := notes[0].left_hand_vibrato.(string)
	testing.expect(t, !is_word)
	testing.expect_value(t, notes[1].left_hand_vibrato.(string), "slight")
	testing.expect_value(t, notes[2].left_hand_vibrato.(string), "wide")
}

@(test)
guitar_tracks_is_empty_without_a_guitar :: proc(t: ^testing.T) {
	info := Song_Info{tracks = []Track_Meta{{hash = "vocals_a"}, {hash = "guitar_b", is_empty = true}}}
	tracks := guitar_tracks(info)
	defer delete(tracks)
	testing.expect_value(t, len(tracks), 0)
}
