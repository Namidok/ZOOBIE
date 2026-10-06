import Foundation
import Testing
@testable import CompanionCore

@Suite struct QuickCommandTests {
    private func match(_ text: String) -> QuickCommand? { QuickCommand.match(text) }

    @Test func opensApps() {
        #expect(match("open safari") == .openApp("Safari"))
        #expect(match("Open Safari.") == .openApp("Safari")) // speech adds capitals and a full stop
        #expect(match("hey zoobie, can you open spotify please") == .openApp("Spotify"))
        #expect(match("launch the terminal app") == .openApp("Terminal"))
        #expect(match("switch to system settings") == .openApp("System Settings"))
    }

    @Test func leavesHarderRequestsToTheModel() {
        for text in ["open a new tab in safari", "open my downloads folder", "open the file I was editing",
                     "start the server", "what's the difference between a process and a thread?",
                     "open safari and go to github", "remind me to call mom tomorrow at 6pm", "skip the intro",
                     "turn it up a notch in the essay", "what time does the store close"] {
            #expect(match(text) == nil, "\(text)")
        }
    }

    @Test func opensWebsites() {
        #expect(match("go to github.com") == .openWebsite(url: "https://github.com", browser: nil))
        #expect(match("go to github.com in safari") == .openWebsite(url: "https://github.com", browser: "Safari"))
        #expect(match("open youtube.com in chrome") == .openWebsite(url: "https://youtube.com", browser: "Google Chrome"))
        #expect(match("Open news.ycombinator.com.") == .openWebsite(url: "https://news.ycombinator.com", browser: nil))
        #expect(match("go to https://example.org/docs") == .openWebsite(url: "https://example.org/docs", browser: nil))
    }

    @Test func controlsMusic() {
        for text in ["pause", "pause the music", "Pause music.", "stop the music", "pause spotify"] {
            #expect(match(text) == .pause, "\(text)")
        }
        for text in ["play", "resume", "resume the music", "play music", "resume my music", "unpause"] {
            #expect(match(text) == .play, "\(text)")
        }
        for text in ["next song", "skip", "skip this song", "next track", "play the next song"] {
            #expect(match(text) == .next, "\(text)")
        }
        for text in ["previous song", "go back a song", "last track", "play the previous song"] {
            #expect(match(text) == .previous, "\(text)")
        }
    }

    @Test func setsVolume() {
        #expect(match("set the volume to 30 percent") == .setVolume(30))
        #expect(match("volume 45") == .setVolume(45))
        #expect(match("volume to 30%") == .setVolume(30))
        #expect(match("set volume to 150") == .setVolume(100))
        #expect(match("turn it up") == .changeVolume(up: true))
        #expect(match("volume down") == .changeVolume(up: false))
        #expect(match("turn the volume down") == .changeVolume(up: false))
        #expect(match("mute") == .mute(true))
        #expect(match("unmute") == .mute(false))
    }

    @Test func setsTimers() {
        #expect(match("set a timer for 10 minutes for pasta") == .timer(seconds: 600, label: "pasta"))
        #expect(match("timer for 5 min") == .timer(seconds: 300, label: "Timer"))
        #expect(match("start a timer for thirty seconds") == .timer(seconds: 30, label: "Timer"))
        #expect(match("set a 15 minute timer") == .timer(seconds: 900, label: "Timer"))
        #expect(match("set a timer for an hour") == .timer(seconds: 3600, label: "Timer"))
        #expect(match("timer for half an hour for laundry") == .timer(seconds: 1800, label: "laundry"))
    }

    @Test func tellsTimeAndDate() {
        #expect(match("what time is it?") == .time)
        #expect(match("What's the time") == .time)
        #expect(match("what's the date today") == .date)
        #expect(match("what day is it") == .date)
    }

    @Test func turnsCommandsIntoActions() {
        #expect(QuickCommand.openApp("Safari").action == .openApp("Safari"))
        #expect(QuickCommand.openWebsite(url: "https://github.com", browser: nil).action == .openURL("https://github.com"))
        #expect(QuickCommand.pause.action == .media("play_pause"))
        #expect(QuickCommand.next.action == .media("next"))
        #expect(QuickCommand.setVolume(30).action == .appleScript("set volume output volume 30"))
        #expect(QuickCommand.timer(seconds: 600, label: "pasta").action == .setTimer(seconds: 600, label: "pasta"))
        #expect(QuickCommand.time.action == nil)
        for command in [QuickCommand.openApp("Safari"), .openWebsite(url: "https://a.com", browser: "Safari"), .pause, .play,
                        .next, .previous, .setVolume(10), .changeVolume(up: true), .mute(true), .timer(seconds: 60, label: "x")] {
            #expect(command.action?.needsApproval(under: .risky) == false, "\(command)")
        }
    }

    @Test func repliesFromTheResult() {
        #expect(QuickCommand.openApp("Safari").reply(to: "Safari is open and in front.") == "Safari's open.")
        // A failure goes back to the model, which can work out what was meant.
        #expect(QuickCommand.openApp("Youtube").reply(to: "Couldn't open Youtube: Unable to find application named 'Youtube'") == nil)
        #expect(QuickCommand.pause.reply(to: "Pressed the play/pause media key.") == "Paused.")
        #expect(QuickCommand.pause.reply(to: "Error: Accessibility permission is off") == nil)
        #expect(QuickCommand.setVolume(30).reply(to: "Done.") == "Volume's at 30.")
        let twenty = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 13, minute: 42))!
        #expect(QuickCommand.time.reply(to: "", now: twenty)?.contains("1:42") == true)
        #expect(QuickCommand.date.reply(to: "", now: twenty)?.contains("October 6") == true)
    }
}
