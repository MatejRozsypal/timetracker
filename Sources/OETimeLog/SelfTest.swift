import Foundation

/// `OETimeLog --selftest` checks the title grammar without launching the UI.
enum SelfTest {
    static func run() -> Int32 {
        let book = Codebook(
            clients: [Client(code: "oe", name: "One Eighty"), Client(code: "dob", name: "Dobias")],
            activities: [
                Activity(code: "meta", name: "Meta", bucket: "delivering", tier: "L2"),
                Activity(code: "sales", name: "Sales", bucket: "promoting", tier: "L3"),
            ])
        var failures = 0
        func check(_ input: String, client: String?, activity: String?, energy: String? = nil,
                   note: String = "", rating: Rating? = nil, valid: Bool = true) {
            let p = Parser.parse(input, codebook: book)
            let ok = p.client?.code == client && p.activity?.code == activity && p.energy == energy
                && p.note == note && p.rating == rating && p.isValid == valid
            print((ok ? "ok   " : "FAIL ") + "\"\(input)\" -> \(p.client?.code ?? "-") \(p.activity?.code ?? "-") \(p.energy ?? "") [\(p.note)] \(p.rating?.rawValue ?? "unrated") \(p.error ?? "")")
            if !ok { failures += 1 }
        }
        check("dob meta + scaling test review g", client: "dob", activity: "meta", energy: "+", note: "scaling test review", rating: .green)
        check("dob meta scaling test", client: "dob", activity: "meta", note: "scaling test")
        check("sales follow-ups r", client: "oe", activity: "sales", note: "follow-ups", rating: .red)
        check("DOB META o", client: "dob", activity: "meta", rating: .orange)
        check("dob - meta", client: "dob", activity: nil, energy: "-", note: "meta", valid: false)
        check("xyz meta", client: nil, activity: nil, note: "xyz meta", valid: false)
        check("dob", client: "dob", activity: nil, valid: false)

        let done = Parser.complete("dob me", with: "meta")
        print((done == "dob meta " ? "ok   " : "FAIL ") + "complete -> \"\(done)\"")
        if done != "dob meta " { failures += 1 }

        print(failures == 0 ? "All checks passed" : "\(failures) failed")
        return failures == 0 ? 0 : 1
    }
}
