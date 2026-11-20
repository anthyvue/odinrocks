// Fetches the Songsterr documents of a song. This is the only package that uses the network.
package fetch

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "../songsterr"

// Songsterr serves a tab from one of several CloudFront hosts. The storage key says which group to try.
@(private, rodata)
CDN_HOSTS := [?]string{"dqsljvtekg760", "d34shlm8p2ums2", "d3cqchs6g3b5ew"}
@(private, rodata)
STAGE_CDN_HOSTS := [?]string{"d3d3l6a6rcgkaf"}
@(private, rodata)
LEGACY_CDN_HOSTS := [?]string{"d3rrfvx08uyjp1", "dodkcbujl0ebx", "dj1usja78sinh"}

// One entry of the video-points list: a YouTube video and where each bar starts in it.
// feature is null for the full mix and names the part for any other video.
@(private)
Video_Points :: struct {
	video_id: string `json:"videoId"`,
	status:   string `json:"status"`,
	feature:  string `json:"feature"`,
	points:   []f64  `json:"points"`,
}

song_info :: proc(song_id: int) -> (info: songsterr.Song_Info, ok: bool) {
	url := fmt.tprintf("https://www.songsterr.com/api/meta/%d", song_id)
	body := document(url) or_return
	return parse_json(body, songsterr.Song_Info, "song info")
}

// Fails when the request does, or when the song has no full-mix video.
full_mix :: proc(info: songsterr.Song_Info) -> (mix: songsterr.Full_Mix, ok: bool) {
	url := fmt.tprintf("https://www.songsterr.com/api/video-points/%d/%d/list", info.song_id, info.revision_id)
	body := document(url) or_return
	listing := parse_json(body, []Video_Points, "video points") or_return
	return find_full_mix(listing)
}

// Tries every mirror that can hold the tab of track.
tab :: proc(info: songsterr.Song_Info, track: int) -> (guitar_tab: songsterr.Tab, ok: bool) {
	body := first_available(tab_urls(info, track)) or_return
	return parse_json(body, songsterr.Tab, "tab")
}

// Prints why to stderr and returns false when body is not a T.
@(private)
parse_json :: proc(body: []byte, $T: typeid, what: string) -> (value: T, ok: bool) {
	if err := json.unmarshal(body, &value); err != nil {
		fmt.eprintfln("%s: %v", what, err)
		return {}, false
	}
	return value, true
}

// The first video that is the full mix. A null feature arrives as an empty string. Its times must strictly increase.
@(private)
find_full_mix :: proc(listing: []Video_Points) -> (mix: songsterr.Full_Mix, found: bool) {
	for video in listing {
		if video.feature != "" || video.status != "done" || !strictly_increase(video.points) do continue
		return {video_id = video.video_id, measure_times = video.points}, true
	}
	return
}

@(private)
strictly_increase :: proc(times: []f64) -> bool {
	if len(times) == 0 do return false
	for index in 1 ..< len(times) {
		if times[index] <= times[index - 1] do return false
	}
	return true
}

@(private)
tab_urls :: proc(info: songsterr.Song_Info, track: int) -> []string {
	if info.storage_key == "" {
		return cdn_urls(LEGACY_CDN_HOSTS[:], fmt.tprintf("part/%d/%d", info.revision_id, track))
	}
	path := fmt.tprintf("%d/%d/%s/%d.json", info.song_id, info.revision_id, info.storage_key, track)
	if strings.has_suffix(info.storage_key, "-stage") do return cdn_urls(STAGE_CDN_HOSTS[:], path)
	return cdn_urls(CDN_HOSTS[:], path)
}

@(private)
cdn_urls :: proc(hosts: []string, path: string) -> []string {
	urls := make([]string, len(hosts), context.temp_allocator)
	for host, index in hosts do urls[index] = fmt.tprintf("https://%s.cloudfront.net/%s", host, path)
	return urls
}
