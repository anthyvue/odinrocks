package fetch

import "core:testing"
import "../songsterr"

@(test)
full_mix_is_the_finished_featureless_video_with_increasing_times :: proc(t: ^testing.T) {
	listing := []Video_Points{
		{video_id = "solo", status = "done", feature = "solo", points = {1, 2, 3}},
		{video_id = "pending", status = "processing", points = {1, 2, 3}},
		{video_id = "no_points", status = "done"},
		{video_id = "stuck", status = "done", points = {1, 2, 2}},
		{video_id = "mix", status = "done", points = {1, 2, 3}},
		{video_id = "second_mix", status = "done", points = {4, 5}},
	}
	mix, found := find_full_mix(listing)
	testing.expect(t, found)
	testing.expect_value(t, mix.video_id, "mix")
	testing.expect_value(t, len(mix.measure_times), 3)

	_, found = find_full_mix(listing[:4])
	testing.expect(t, !found)
}

@(test)
tab_urls_follow_the_storage_key :: proc(t: ^testing.T) {
	info := songsterr.Song_Info{song_id = 7, revision_id = 9, storage_key = "v0-key"}

	regular := tab_urls(info, 2)
	testing.expect_value(t, len(regular), len(CDN_HOSTS))
	testing.expect_value(t, regular[1], "https://d34shlm8p2ums2.cloudfront.net/7/9/v0-key/2.json")

	info.storage_key = "v0-key-stage"
	stage := tab_urls(info, 2)
	testing.expect_value(t, len(stage), 1)
	testing.expect_value(t, stage[0], "https://d3d3l6a6rcgkaf.cloudfront.net/7/9/v0-key-stage/2.json")

	info.storage_key = ""
	legacy := tab_urls(info, 2)
	testing.expect_value(t, len(legacy), len(LEGACY_CDN_HOSTS))
	testing.expect_value(t, legacy[0], "https://d3rrfvx08uyjp1.cloudfront.net/part/9/2")
}

@(test)
malformed_json_is_not_ok :: proc(t: ^testing.T) {
	_, ok := parse_json(transmute([]byte)string(`{"tracks":`), songsterr.Song_Info, "song info")
	testing.expect(t, !ok)
}
