// Downloads the audio of a YouTube video with yt-dlp. It is the only package that runs other programs, so it also knows which ones the app needs.
package youtube

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "../pcm"

// yt-dlp, the QuickJS that it runs YouTube's scripts with, and the ffmpeg that it converts the audio with.
@(private, rodata)
REQUIRED_TOOLS := [?]string{"yt-dlp", "qjs", "ffmpeg"}
// About one download in thirty gets a 403 on its first media request, and yt-dlp does not retry a 403 itself.
// A new yt-dlp run extracts a new media URL, and that one works.
@(private)
DOWNLOAD_ATTEMPTS :: 3

missing_tools :: proc() -> []string {
	missing: [dynamic]string
	for name in REQUIRED_TOOLS do if !on_path(name) do append(&missing, name)
	return missing[:]
}

// Writes the audio of the YouTube video to the wav at path. Prints why to stderr and returns false when it cannot.
download_full_mix :: proc(video_id, path: string) -> (ok: bool) {
	for attempt in 1 ..= DOWNLOAD_ATTEMPTS {
		if download_once(video_id, path) do return true
		fmt.eprintfln("youtube %s: attempt %d of %d failed", video_id, attempt, DOWNLOAD_ATTEMPTS)
	}
	return false
}

@(private)
download_once :: proc(video_id, path: string) -> (ok: bool) {
	ok = run({
		"yt-dlp",
		// 251 is opus at 48000 Hz. AAC (format 140) is about 36 ms late against it, so a fallback would shift every gem.
		"-f", "251",
		"-x",
		"--force-overwrites",
		"--audio-format",
		"wav",
		"--postprocessor-args",
		fmt.tprintf("ffmpeg:-ac 2 -ar %d", pcm.SAMPLE_RATE),
		"--js-runtimes",
		"quickjs",
		"-o",
		fmt.tprintf("%s.%%(ext)s", strings.trim_suffix(path, ".wav")),
		fmt.tprintf("https://www.youtube.com/watch?v=%s", video_id),
	})
	if !ok {
		os.remove(path)
		return false
	}
	if !os.exists(path) {
		fmt.eprintfln("yt-dlp did not write %s", path)
		return false
	}
	return true
}

// Reports whether name.exe is in a directory of PATH. It only looks: starting the program costs about a second for yt-dlp.
@(private)
on_path :: proc(name: string) -> bool {
	exe := fmt.tprintf("%s.exe", name)
	path := os.get_env("PATH", context.temp_allocator)
	for dir in strings.split_iterator(&path, ";") {
		if os.exists(filepath.join({strings.trim(dir, "\""), exe}, context.temp_allocator) or_else "") do return true
	}
	return false
}

// Runs the program and streams its output to the console. Returns false, and says why on stderr, when it cannot run or does not exit 0.
@(private)
run :: proc(args: []string) -> (ok: bool) {
	process, start_err := os.process_start({
		command = args,
		stdout = os.stdout,
		stderr = os.stderr,
	})
	if start_err != nil {
		fmt.eprintfln("%s: %v", args[0], start_err)
		return false
	}
	state, wait_err := os.process_wait(process)
	if wait_err != nil {
		fmt.eprintfln("%s: %v", args[0], wait_err)
		return false
	}
	if state.exit_code != 0 {
		fmt.eprintfln("%s exited %d", args[0], state.exit_code)
		return false
	}
	return true
}
