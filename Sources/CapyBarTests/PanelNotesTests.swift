import CapyBarCore

@MainActor
func panelNotesTests() {
    section("Panel notes")

    let busy = "Alpha isn’t responding."
    let login = "Couldn’t change Open at Login."

    var notes = PanelNotes()
    notes.postNewlyHidden(["a": "Alpha"])
    notes.postNewlyHidden(["b": "Bravo"])
    check(notes.lines == ["Now hidden: Alpha, Bravo."], "apps hidden before the panel opens add up")

    notes.appToggled("a")
    check(notes.lines == ["Now hidden: Bravo."], "showing an app again takes it out of the news")
    notes.appToggled("b")
    check(notes.lines.isEmpty, "the news goes once every app in it is shown again")

    notes.postNewlyHidden(["a": "Alpha"])
    notes.appsQuit(["a"])
    check(notes.lines == ["Now hidden: Alpha."], "a quit app stays hidden, so its news stays")
    notes.everythingShown()
    check(notes.lines.isEmpty, "Show All Icons drops the news of apps just hidden")

    notes.post(.app(bundleID: "a", text: busy))
    notes.appToggled("b")
    check(notes.report != nil, "toggling another app keeps an app's error")
    notes.everythingShown()
    check(notes.report != nil, "Show All Icons keeps an app's error")
    notes.appsQuit(["a"])
    check(notes.report == nil, "an app's error goes when it quits")

    notes.post(.app(bundleID: "a", text: "Alpha has no menu bar icon."))
    notes.appToggled("a")
    check(notes.report == nil, "an app's error goes when it is shown or hidden again")

    notes.postNewlyHidden(["b": "Bravo"])
    notes.post(.app(bundleID: "a", text: busy))
    notes.post(.general(login))
    check(notes.lines == ["Now hidden: Bravo.", login], "a report replaces the last one, never the news")
    notes.clearReport()
    check(notes.lines == ["Now hidden: Bravo."], "starting something new clears the report, not the news")
    notes.everythingShown()

    notes.post(.general(login))
    notes.panelClosed()
    check(notes.report != nil, "a close without an opening drops nothing")
    notes.panelOpened()
    notes.panelClosed()
    check(notes.report == nil, "a note goes once the panel showing it closes")

    notes.post(.general(login))
    notes.panelOpened(showsNotes: false)
    notes.panelClosed()
    check(notes.report != nil, "a panel that couldn't show notes leaves them for later")
    notes.panelOpened()
    notes.panelClosed()
    check(notes.report == nil, "they go once a panel showed them")

    notes.panelOpened()
    notes.post(.general(login))
    notes.postNewlyHidden(["b": "Bravo"])
    notes.panelClosed()
    check(notes.lines.isEmpty, "notes posted while the panel is open go when it closes")

    notes.panelOpened()
    notes.panelClosed()
    notes.post(.app(bundleID: "a", text: busy))
    notes.panelClosed()
    check(notes.report != nil, "a late second close keeps a note posted after the first")

    notes.panelOpened()
    notes.postNewlyHidden(["b": "Bravo"])
    notes.postNewlyHidden(["c": "Charlie"])
    notes.panelClosed()
    check(notes.lines.isEmpty, "news that grew while shown goes when the panel closes")
}
