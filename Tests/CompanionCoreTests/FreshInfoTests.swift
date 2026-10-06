import Foundation
import Testing
@testable import CompanionCore

@Suite struct FreshInfoTests {
    @Test func searchesWhenTheAnswerDependsOnNow() {
        #expect(FreshInfo.query(for: "Zoobs can you give me fun things to do in berlin right now?", names: ["Zoobs"])
            == "fun things to do in berlin right now")
        for text in ["what's the weather in Munich tomorrow", "any good concerts in Berlin this weekend?",
                     "what's the latest news about OpenAI", "what's the price of bitcoin", "who won the Bayern game today",
                     "is the Apple store on Kurfürstendamm open now", "what events are happening in Hamburg tonight"] {
            #expect(FreshInfo.query(for: text) != nil, "\(text)")
        }
    }

    @Test func leavesTimelessAndPersonalRequestsAlone() {
        for text in ["what's the difference between a process and a thread?", "what's on my calendar today?",
                     "remind me to call mom tomorrow at 6pm", "set a timer for 10 minutes", "open safari",
                     "how do I reverse a list in python?", "I'm sad Zoobs", "what's wrong with this code?",
                     "add a meeting with Anna tomorrow at 3", "what did I do today in my notes", "email Tom about today's demo"] {
            #expect(FreshInfo.query(for: text) == nil, "\(text)")
        }
    }

    @Test func briefingNamesTodayAndTheResults() {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 14, minute: 30))!
        let block = FreshInfo.briefing(results: "1. Festival of Lights — Berlin, 2–11 Oct", now: date)
        #expect(block.contains("2026-10-06"))
        #expect(block.contains("Festival of Lights"))
    }
}
