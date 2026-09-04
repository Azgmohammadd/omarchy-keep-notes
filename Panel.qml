import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons

Item {
    id: root

    property var shell: null
    property var manifest: null

    property bool opened: false
    property bool loading: false
    property bool mutating: false
    property string errorMessage: ""
    property string statusMessage: ""
    property string currentTab: "todo"
    property string searchText: ""
    property string captureMode: "todo"
    property string lastPayload: "{}"

    property bool connectionKnown: false
    property bool connected: false
    property string connectedEmail: ""
    property bool authenticating: false
    property string authError: ""
    property bool authTokenVisible: false

    property string todoListId: ""
    property string todoTitle: "Keep Notes TODO"
    property var todoItemsData: []
    property var notesData: []
    property var pinnedData: []

    property int selectedTodoIndex: 0
    property int selectedNoteIndex: 0
    property int selectedPinnedIndex: 0

    property bool vimGArmed: false
    property string editingTodoId: ""

    property bool editorOpen: false
    property string editorNoteId: ""
    property string editorType: "text"
    property bool editorPinned: false
    property int editorSelectedIndex: -1

    readonly property string pluginId:
        (manifest && manifest.id) ? manifest.id : "dev.zed.keep-notes"
    readonly property color panelColor: Color.background
    readonly property color textColor: Color.foreground
    readonly property color mutedColor: Qt.rgba(textColor.r, textColor.g, textColor.b, 0.58)
    readonly property color subtleColor: Qt.rgba(textColor.r, textColor.g, textColor.b, 0.075)
    readonly property color hoverColor: Qt.rgba(textColor.r, textColor.g, textColor.b, 0.12)
    readonly property color borderColor: Qt.rgba(textColor.r, textColor.g, textColor.b, 0.16)
    readonly property color selectedColor: Qt.rgba(textColor.r, textColor.g, textColor.b, 0.11)
    readonly property color accentColor: Color.accent
    readonly property string fontFamily: Style.font.family

    ListModel { id: todoModel }
    ListModel { id: notesModel }
    ListModel { id: pinnedModel }
    ListModel { id: editorItemsModel }

    Timer {
        id: vimGTimer
        interval: 650
        repeat: false
        onTriggered: root.vimGArmed = false
    }

    function dismiss() {
        if (root.shell && typeof root.shell.hide === "function")
            root.shell.hide(root.pluginId)
        else
            close()
    }

    function open(payloadJson) {
        lastPayload = payloadJson || "{}"
        errorMessage = ""
        statusMessage = ""
        editorOpen = false
        editingTodoId = ""
        opened = true

        var payload = {}
        try { payload = JSON.parse(lastPayload) || {} } catch (e) {}

        if (payload.tab === "todo" || payload.tab === "notes" || payload.tab === "pinned")
            currentTab = payload.tab

        Qt.callLater(function() {
            if (!opened) return
            panelKeys.forceActiveFocus()
            checkConnection()
        })
    }

    function close() {
        opened = false
        editorOpen = false
        editingTodoId = ""
        vimGArmed = false
        errorMessage = ""
        statusMessage = ""
        searchText = ""
        if (statusProc.running) statusProc.running = false
        if (authProc.running) authProc.running = false
        if (dataProc.running) dataProc.running = false
        if (mutationProc.running) mutationProc.running = false
    }

    function bridgeCommand(args) {
        var bridge = Quickshell.env("HOME")
            + "/.config/omarchy/plugins/"
            + root.pluginId
            + "/bin/keep-notes"
        var cmd = [bridge]
        for (var i = 0; i < args.length; i++)
            cmd.push(String(args[i]))
        return cmd
    }

    function checkConnection() {
        if (statusProc.running || authProc.running) return
        connectionKnown = false
        authError = ""
        statusProc.command = bridgeCommand(["status"])
        statusProc.running = true
    }

    function startAuthentication() {
        var email = authEmail.text.trim()
        var token = authToken.text.trim()

        authError = ""

        if (!email) {
            authError = "Enter your Google account email."
            authEmail.forceActiveFocus()
            return
        }

        if (!token) {
            authError = "Paste the oauth_token cookie from Google Embedded Setup."
            authToken.forceActiveFocus()
            return
        }

        if (!token.startsWith("oauth2_4/") && !token.startsWith("oauth2_1/")) {
            authError = "The oauth_token should start with oauth2_4/ (or oauth2_1/)."
            authToken.forceActiveFocus()
            return
        }

        if (authProc.running) return

        authenticating = true
        authProc.command = bridgeCommand(["bootstrap-stdin"])
        authProc.running = true
    }

    function openGoogleSetup() {
        if (browserProc.running) return
        browserProc.command = ["xdg-open", "https://accounts.google.com/EmbeddedSetup"]
        browserProc.running = true
    }

    function refresh() {
        if (!connected || loading || dataProc.running || mutationProc.running) return
        loading = true
        errorMessage = ""
        statusMessage = "Syncing…"
        dataProc.command = bridgeCommand(["snapshot", "--sync"])
        dataProc.running = true
    }

    function loadSnapshot(raw) {
        var payload
        try {
            payload = JSON.parse(raw)
        } catch (e) {
            errorMessage = "Keep returned malformed data."
            return
        }

        if (!payload.ok) {
            var message = payload.error || "Could not load Google Keep."
            var lowered = String(message).toLowerCase()

            if (lowered.indexOf("authentication") >= 0 ||
                lowered.indexOf("not connected") >= 0) {
                connected = false
                connectionKnown = true
                authError = message
                errorMessage = ""
                statusMessage = ""
                Qt.callLater(function() {
                    if (root.opened)
                        authToken.forceActiveFocus()
                })
            } else {
                errorMessage = message
            }
            return
        }

        var todo = payload.todo || {}
        todoListId = todo.listId || ""
        todoTitle = todo.title || "Keep Notes TODO"
        todoItemsData = todo.items || []
        notesData = payload.notes || []
        pinnedData = payload.pinned || []

        rebuildModels()
        statusMessage = payload.syncedAt ? ("Synced " + payload.syncedAt) : "Synced"
    }

    function rebuildModels() {
        todoModel.clear()
        notesModel.clear()
        pinnedModel.clear()

        var q = searchText.trim().toLowerCase()

        for (var i = 0; i < todoItemsData.length; i++) {
            var todo = todoItemsData[i]
            var todoHaystack = String(todo.itemText || "").toLowerCase()
            if (!q || todoHaystack.indexOf(q) >= 0)
                todoModel.append(todo)
        }

        for (var j = 0; j < notesData.length; j++) {
            var note = notesData[j]
            var noteHaystack = (
                String(note.noteTitle || "") + " " +
                String(note.noteText || "") + " " +
                String(note.previewText || "") + " " +
                String(note.labelsText || "")
            ).toLowerCase()

            if (!q || noteHaystack.indexOf(q) >= 0)
                notesModel.append(note)
        }

        for (var k = 0; k < pinnedData.length; k++) {
            var pinned = pinnedData[k]
            var pinnedHaystack = (
                String(pinned.noteTitle || "") + " " +
                String(pinned.noteText || "") + " " +
                String(pinned.previewText || "") + " " +
                String(pinned.labelsText || "")
            ).toLowerCase()

            if (!q || pinnedHaystack.indexOf(q) >= 0)
                pinnedModel.append(pinned)
        }

        selectedTodoIndex = clampIndex(selectedTodoIndex, todoModel.count)
        selectedNoteIndex = clampIndex(selectedNoteIndex, notesModel.count)
        selectedPinnedIndex = clampIndex(selectedPinnedIndex, pinnedModel.count)
        syncCurrentIndex()
    }

    function clampIndex(index, count) {
        if (count <= 0) return -1
        return Math.max(0, Math.min(index, count - 1))
    }

    function currentCount() {
        if (currentTab === "todo") return todoModel.count
        if (currentTab === "notes") return notesModel.count
        return pinnedModel.count
    }

    function currentSelectedIndex() {
        if (currentTab === "todo") return selectedTodoIndex
        if (currentTab === "notes") return selectedNoteIndex
        return selectedPinnedIndex
    }

    function setCurrentSelectedIndex(index) {
        var count = currentCount()
        var next = clampIndex(index, count)

        if (currentTab === "todo") {
            selectedTodoIndex = next
            todoView.currentIndex = next
            if (next >= 0) todoView.positionViewAtIndex(next, ListView.Contain)
        } else if (currentTab === "notes") {
            selectedNoteIndex = next
            notesView.currentIndex = next
            if (next >= 0) notesView.positionViewAtIndex(next, ListView.Contain)
        } else {
            selectedPinnedIndex = next
            pinnedView.currentIndex = next
            if (next >= 0) pinnedView.positionViewAtIndex(next, ListView.Contain)
        }
    }

    function syncCurrentIndex() {
        todoView.currentIndex = selectedTodoIndex
        notesView.currentIndex = selectedNoteIndex
        pinnedView.currentIndex = selectedPinnedIndex
    }

    function moveSelection(delta) {
        if (currentCount() <= 0) return
        editingTodoId = ""
        var index = currentSelectedIndex()
        if (index < 0) index = 0
        setCurrentSelectedIndex(index + delta)
    }

    function goFirst() {
        if (currentCount() > 0)
            setCurrentSelectedIndex(0)
    }

    function goLast() {
        if (currentCount() > 0)
            setCurrentSelectedIndex(currentCount() - 1)
    }

    function tabIndex() {
        if (currentTab === "todo") return 0
        if (currentTab === "notes") return 1
        return 2
    }

    function moveTab(delta) {
        var tabs = ["todo", "notes", "pinned"]
        var idx = (tabIndex() + delta + tabs.length) % tabs.length
        currentTab = tabs[idx]
        editingTodoId = ""
        vimGArmed = false
        syncCurrentIndex()
    }

    function mutate(args, successText) {
        if (mutationProc.running || dataProc.running) return
        mutating = true
        errorMessage = ""
        statusMessage = ""
        mutationProc.pendingSuccess = successText || ""
        mutationProc.command = bridgeCommand(args)
        mutationProc.running = true
    }

    function toggleTodo(itemId, checked) {
        if (!todoListId) return
        mutate(
            ["toggle-todo", todoListId, itemId, checked ? "false" : "true"],
            "TODO updated"
        )
    }

    function toggleSelectedTodo() {
        if (currentTab !== "todo" || selectedTodoIndex < 0 || selectedTodoIndex >= todoModel.count)
            return
        var item = todoModel.get(selectedTodoIndex)
        toggleTodo(item.itemId, item.checked)
    }

    function beginTodoEdit(index) {
        if (index < 0 || index >= todoModel.count) return
        setCurrentSelectedIndex(index)
        editingTodoId = todoModel.get(index).itemId
    }

    function editSelectedTodo() {
        if (currentTab === "todo")
            beginTodoEdit(selectedTodoIndex)
    }

    function saveTodoEdit(itemId, text) {
        var value = String(text || "").trim()
        editingTodoId = ""
        panelKeys.forceActiveFocus()
        if (!todoListId || !itemId || !value) return
        mutate(["update-todo", todoListId, itemId, value], "TODO edited")
    }

    function deleteTodo(itemId) {
        if (!todoListId || !itemId) return
        editingTodoId = ""
        mutate(["delete-todo", todoListId, itemId], "TODO deleted")
    }

    function quickCapture() {
        var value = captureInput.text.trim()
        if (!value || mutating || loading) return

        if (captureMode === "todo") {
            mutate(["add-todo", value], "TODO added")
        } else if (captureMode === "checklist") {
            mutate(["create-list", "--title", value], "Checklist created")
        } else {
            mutate(["add-note", "--title", value, "--text", ""], "Note created")
        }

        captureInput.text = ""
    }

    function cycleCaptureMode() {
        if (captureMode === "todo") captureMode = "note"
        else if (captureMode === "note") captureMode = "checklist"
        else captureMode = "todo"
    }

    function activateSelected() {
        var index = currentSelectedIndex()
        if (index < 0) return

        if (currentTab === "todo") {
            beginTodoEdit(index)
            return
        }

        var note = currentTab === "notes"
            ? notesModel.get(index)
            : pinnedModel.get(index)

        openEditor(
            note.noteId,
            note.noteTitle,
            note.noteText,
            note.noteType,
            note.pinned,
            note.itemsJson
        )
    }

    function openEditor(noteId, noteTitle, noteText, noteType, pinned, itemsJson) {
        editorNoteId = noteId
        editorType = noteType || "text"
        editorPinned = pinned === true
        editorTitle.text = noteTitle || ""
        editorBody.text = noteText || ""
        editorItemsModel.clear()
        editorNewItem.text = ""
        editorSelectedIndex = -1

        if (editorType === "list") {
            var items = []
            try { items = JSON.parse(itemsJson || "[]") || [] } catch (e) {}
            for (var i = 0; i < items.length; i++)
                editorItemsModel.append(items[i])
            if (editorItemsModel.count > 0)
                editorSelectedIndex = 0
        }

        editorOpen = true
        Qt.callLater(function() {
            if (editorOpen)
                editorTitle.forceActiveFocus()
        })
    }

    function editorItemsJson() {
        var rows = []
        for (var i = 0; i < editorItemsModel.count; i++) {
            var item = editorItemsModel.get(i)
            rows.push({
                itemId: item.itemId || "",
                itemText: item.itemText || "",
                checked: item.checked === true
            })
        }
        return JSON.stringify(rows)
    }

    function addEditorItem() {
        var value = editorNewItem.text.trim()
        if (!value) return
        editorItemsModel.append({
            itemId: "",
            itemText: value,
            checked: false
        })
        editorNewItem.text = ""
        editorNewItem.forceActiveFocus()
    }

    function saveEditor() {
        if (!editorNoteId || mutating || loading) return
        var title = editorTitle.text.trim()

        if (editorType === "list") {
            mutate([
                "update-list",
                editorNoteId,
                "--title", title,
                "--items-json", editorItemsJson()
            ], "Checklist saved")
        } else {
            mutate([
                "update-note",
                editorNoteId,
                "--title", title,
                "--text", editorBody.text
            ], "Note saved")
        }

        editorOpen = false
        panelKeys.forceActiveFocus()
    }

    function archiveEditor() {
        if (!editorNoteId) return
        mutate(["archive", editorNoteId], "Archived")
        editorOpen = false
        panelKeys.forceActiveFocus()
    }

    function toggleEditorPin() {
        if (!editorNoteId || mutating || loading) return
        editorPinned = !editorPinned
        mutate(["pin", editorNoteId, editorPinned ? "true" : "false"],
               editorPinned ? "Pinned" : "Unpinned")
    }

    function setEditorSelectedIndex(index) {
        if (editorType !== "list") return
        if (editorItemsModel.count <= 0) {
            editorSelectedIndex = -1
            return
        }
        editorSelectedIndex = Math.max(0, Math.min(index, editorItemsModel.count - 1))
        editorItemsView.currentIndex = editorSelectedIndex
        editorItemsView.positionViewAtIndex(editorSelectedIndex, ListView.Contain)
    }

    function moveEditorSelection(delta) {
        if (editorType !== "list" || editorItemsModel.count <= 0) return
        var index = editorSelectedIndex
        if (index < 0) index = 0
        setEditorSelectedIndex(index + delta)
    }

    function focusEditorItem(index) {
        if (editorType !== "list" || editorItemsModel.count <= 0) return
        setEditorSelectedIndex(index)
        Qt.callLater(function() {
            var item = editorItemsView.itemAtIndex(root.editorSelectedIndex)
            if (item && typeof item.focusText === "function")
                item.focusText()
        })
    }

    function toggleEditorSelectedItem() {
        if (editorType !== "list" ||
            editorSelectedIndex < 0 ||
            editorSelectedIndex >= editorItemsModel.count)
            return

        var item = editorItemsModel.get(editorSelectedIndex)
        editorItemsModel.setProperty(editorSelectedIndex, "checked", !item.checked)
    }

    function deleteEditorSelectedItem() {
        if (editorType !== "list" ||
            editorSelectedIndex < 0 ||
            editorSelectedIndex >= editorItemsModel.count)
            return

        var next = editorSelectedIndex
        editorItemsModel.remove(editorSelectedIndex)
        if (editorItemsModel.count === 0) {
            editorSelectedIndex = -1
        } else {
            setEditorSelectedIndex(Math.min(next, editorItemsModel.count - 1))
        }
    }

    function focusEditorBody() {
        if (editorType === "text")
            editorBody.forceActiveFocus()
        else if (editorItemsModel.count > 0)
            focusEditorItem(editorSelectedIndex >= 0 ? editorSelectedIndex : 0)
        else
            editorNewItem.forceActiveFocus()
    }

    onSearchTextChanged: rebuildModels()
    onCurrentTabChanged: {
        editingTodoId = ""
        syncCurrentIndex()
    }

    Process {
        id: browserProc
    }

    Process {
        id: statusProc
        property bool responseSeen: false

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var raw = String(text || "").trim()
                if (!raw) return

                statusProc.responseSeen = true
                root.connectionKnown = true

                try {
                    var result = JSON.parse(raw)

                    if (!result.ok) {
                        root.connected = false
                        root.authError = result.error || "Could not read Keep Notes connection status."
                    } else {
                        root.connected = result.connected === true
                        root.connectedEmail = String(result.email || "")
                        root.authError = ""

                        if (root.connected) {
                            Qt.callLater(function() { root.refresh() })
                        } else {
                            Qt.callLater(function() {
                                if (root.opened)
                                    authEmail.forceActiveFocus()
                            })
                        }
                    }
                } catch (e) {
                    root.connected = false
                    root.authError = "Keep Notes returned malformed connection status."
                }
            }
        }

        stderr: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var msg = String(text || "").trim()
                if (msg) root.authError = msg
            }
        }

        onStarted: responseSeen = false

        onExited: function(exitCode) {
            if (exitCode === 0) return

            Qt.callLater(function() {
                if (!statusProc.responseSeen) {
                    root.connectionKnown = true
                    root.connected = false
                    if (root.authError === "")
                        root.authError = "Could not check Google Keep connection."
                }
            })
        }
    }

    Process {
        id: authProc
        stdinEnabled: true
        property bool responseSeen: false

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var raw = String(text || "").trim()
                if (!raw) return

                authProc.responseSeen = true
                root.authenticating = false
                root.connectionKnown = true

                try {
                    var result = JSON.parse(raw)

                    if (result.ok) {
                        root.connected = true
                        root.connectedEmail = String(result.email || authEmail.text.trim())
                        root.authError = ""
                        authToken.text = ""
                        root.statusMessage = "Connected"
                        panelKeys.forceActiveFocus()
                        Qt.callLater(function() { root.refresh() })
                    } else {
                        root.connected = false
                        root.authError = result.error || "Google Keep authentication failed."
                        Qt.callLater(function() {
                            if (root.opened)
                                authToken.forceActiveFocus()
                        })
                    }
                } catch (e) {
                    root.connected = false
                    root.authError = "Keep Notes returned malformed authentication data."
                }
            }
        }

        stderr: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var msg = String(text || "").trim()
                if (msg) root.authError = msg
            }
        }

        onStarted: {
            responseSeen = false
            var payload = JSON.stringify({
                email: authEmail.text.trim(),
                oauth_token: authToken.text.trim()
            })
            write(payload + "\n")
        }

        onExited: function(exitCode) {
            if (exitCode === 0) return

            Qt.callLater(function() {
                if (!authProc.responseSeen) {
                    root.authenticating = false
                    root.connected = false
                    root.connectionKnown = true
                    if (root.authError === "")
                        root.authError = "Google Keep authentication failed."
                    if (root.opened)
                        authToken.forceActiveFocus()
                }
            })
        }
    }

    Process {
        id: dataProc

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.loadSnapshot(String(text || "").trim())
        }

        stderr: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var msg = String(text || "").trim()
                if (msg) root.errorMessage = msg
            }
        }

        onExited: function(exitCode) {
            root.loading = false
            if (exitCode !== 0 && root.errorMessage === "")
                root.errorMessage = "Could not sync Google Keep."
            if (root.errorMessage !== "")
                root.statusMessage = ""
        }
    }

    Process {
        id: mutationProc
        property string pendingSuccess: ""

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var raw = String(text || "").trim()
                if (!raw) return
                try {
                    var result = JSON.parse(raw)
                    if (!result.ok)
                        root.errorMessage = result.error || "Google Keep update failed."
                } catch (e) {
                    root.errorMessage = "Keep returned malformed data."
                }
            }
        }

        stderr: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                var msg = String(text || "").trim()
                if (msg) root.errorMessage = msg
            }
        }

        onExited: function(exitCode) {
            root.mutating = false
            if (exitCode === 0 && root.errorMessage === "") {
                root.statusMessage = pendingSuccess
                Qt.callLater(function() { root.refresh() })
            } else if (root.errorMessage === "") {
                root.errorMessage = "Google Keep update failed."
            }
        }
    }

    PanelWindow {
        visible: root.opened
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.namespace: "keep-notes"
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

        Rectangle {
            anchors.fill: parent
            color: Qt.rgba(0, 0, 0, 0.68)

            MouseArea {
                anchors.fill: parent
                onClicked: root.dismiss()
            }
        }

        Item {
            id: panelKeys
            anchors.fill: parent
            focus: true

            Keys.onEscapePressed: {
                if (root.editorOpen) {
                    root.editorOpen = false
                    editorItemsModel.clear()
                    panelKeys.forceActiveFocus()
                } else if (root.editingTodoId !== "") {
                    root.editingTodoId = ""
                    panelKeys.forceActiveFocus()
                } else {
                    root.dismiss()
                }
            }

            Keys.onPressed: function(event) {
                if (root.editorOpen ||
                    captureInput.activeFocus ||
                    searchInput.activeFocus ||
                    root.editingTodoId !== "")
                    return

                if (event.key === Qt.Key_J || event.key === Qt.Key_Down) {
                    root.moveSelection(1)
                    event.accepted = true
                } else if (event.key === Qt.Key_K || event.key === Qt.Key_Up) {
                    root.moveSelection(-1)
                    event.accepted = true
                } else if (event.text === "g") {
                    if (root.vimGArmed) {
                        root.goFirst()
                        root.vimGArmed = false
                        vimGTimer.stop()
                    } else {
                        root.vimGArmed = true
                        vimGTimer.restart()
                    }
                    event.accepted = true
                } else if (event.text === "G") {
                    root.vimGArmed = false
                    vimGTimer.stop()
                    root.goLast()
                    event.accepted = true
                } else if (event.key === Qt.Key_H || event.key === Qt.Key_Left) {
                    root.moveTab(-1)
                    event.accepted = true
                } else if (event.key === Qt.Key_L || event.key === Qt.Key_Right) {
                    root.moveTab(1)
                    event.accepted = true
                } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    root.activateSelected()
                    event.accepted = true
                } else if (event.key === Qt.Key_Space || event.key === Qt.Key_X) {
                    root.toggleSelectedTodo()
                    event.accepted = true
                } else if (event.key === Qt.Key_E) {
                    root.editSelectedTodo()
                    event.accepted = true
                } else if (event.key === Qt.Key_Slash) {
                    searchInput.forceActiveFocus()
                    event.accepted = true
                } else if (event.key === Qt.Key_A) {
                    captureInput.forceActiveFocus()
                    event.accepted = true
                } else if (event.key === Qt.Key_T) {
                    root.captureMode = "todo"
                    captureInput.forceActiveFocus()
                    event.accepted = true
                } else if (event.key === Qt.Key_N) {
                    root.captureMode = "note"
                    captureInput.forceActiveFocus()
                    event.accepted = true
                } else if (event.key === Qt.Key_C) {
                    root.captureMode = "checklist"
                    captureInput.forceActiveFocus()
                    event.accepted = true
                } else if (event.key === Qt.Key_R) {
                    root.refresh()
                    event.accepted = true
                }
            }

            Rectangle {
                id: card
                anchors.centerIn: parent
                width: Math.min(790, panelKeys.width - Style.space(32))
                height: Math.min(700, panelKeys.height - Style.space(32))
                radius: Style.radius(3)
                color: root.panelColor
                border.width: 1
                border.color: root.borderColor
                clip: true

                MouseArea {
                    anchors.fill: parent
                    onClicked: {}
                }

                ColumnLayout {
                    anchors.fill: parent
                    anchors.margins: Style.space(16)
                    spacing: Style.space(12)

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Style.space(10)

                        Text {
                            text: "Keep Notes"
                            color: root.textColor
                            font.family: root.fontFamily
                            font.pixelSize: 22
                            font.bold: true
                        }

                        Rectangle {
                            width: 7
                            height: 7
                            radius: 4
                            color: root.errorMessage
                                ? "#e06c75"
                                : (root.loading || root.mutating ? "#e5c07b" : "#98c379")
                        }

                        Item { Layout.fillWidth: true }

                        Text {
                            visible: root.statusMessage !== ""
                            text: root.statusMessage
                            color: root.mutedColor
                            font.family: root.fontFamily
                            font.pixelSize: 12
                        }

                        Rectangle {
                            width: 34
                            height: 30
                            radius: Style.radius(1)
                            color: refreshMouse.containsMouse ? root.hoverColor : "transparent"

                            Text {
                                anchors.centerIn: parent
                                text: root.loading ? "…" : "↻"
                                color: root.textColor
                                font.family: root.fontFamily
                                font.pixelSize: 18
                            }

                            MouseArea {
                                id: refreshMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                enabled: !root.loading && !root.mutating
                                onClicked: root.refresh()
                            }
                        }

                        Rectangle {
                            width: 34
                            height: 30
                            radius: Style.radius(1)
                            color: closeMouse.containsMouse ? root.hoverColor : "transparent"

                            Text {
                                anchors.centerIn: parent
                                text: "×"
                                color: root.textColor
                                font.family: root.fontFamily
                                font.pixelSize: 20
                            }

                            MouseArea {
                                id: closeMouse
                                anchors.fill: parent
                                hoverEnabled: true
                                onClicked: root.dismiss()
                            }
                        }
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        height: 38
                        radius: Style.radius(1)
                        color: root.subtleColor
                        border.width: searchInput.activeFocus ? 1 : 0
                        border.color: root.accentColor

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: Style.space(10)
                            anchors.rightMargin: Style.space(10)
                            spacing: Style.space(8)

                            Text {
                                text: "⌕"
                                color: root.mutedColor
                                font.family: root.fontFamily
                                font.pixelSize: 18
                            }

                            TextInput {
                                id: searchInput
                                Layout.fillWidth: true
                                color: root.textColor
                                selectionColor: root.accentColor
                                selectedTextColor: root.panelColor
                                font.family: root.fontFamily
                                font.pixelSize: 14
                                clip: true
                                text: root.searchText

                                onTextChanged: root.searchText = text

                                Text {
                                    anchors.fill: parent
                                    visible: !searchInput.text && !searchInput.activeFocus
                                    text: "Search notes, checklists, and TODOs  /"
                                    color: root.mutedColor
                                    font.family: root.fontFamily
                                    font.pixelSize: 14
                                    verticalAlignment: Text.AlignVCenter
                                }

                                Keys.onEscapePressed: {
                                    searchInput.text = ""
                                    panelKeys.forceActiveFocus()
                                }

                                Keys.onDownPressed: {
                                    panelKeys.forceActiveFocus()
                                    root.moveSelection(1)
                                }
                            }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true
                        spacing: Style.space(6)

                        Repeater {
                            model: [
                                { key: "todo", label: "TODO" },
                                { key: "notes", label: "Notes" },
                                { key: "pinned", label: "Pinned" }
                            ]

                            delegate: Rectangle {
                                required property var modelData
                                height: 34
                                width: tabLabel.implicitWidth + Style.space(20)
                                radius: Style.radius(1)
                                color: root.currentTab === modelData.key
                                    ? root.hoverColor
                                    : "transparent"

                                Text {
                                    id: tabLabel
                                    anchors.centerIn: parent
                                    text: modelData.label
                                    color: root.currentTab === modelData.key
                                        ? root.textColor
                                        : root.mutedColor
                                    font.family: root.fontFamily
                                    font.pixelSize: 13
                                    font.bold: root.currentTab === modelData.key
                                }

                                MouseArea {
                                    anchors.fill: parent
                                    onClicked: {
                                        root.currentTab = modelData.key
                                        panelKeys.forceActiveFocus()
                                    }
                                }
                            }
                        }

                        Item { Layout.fillWidth: true }

                        Text {
                            text: {
                                if (root.currentTab === "todo")
                                    return todoModel.count + " tasks"
                                if (root.currentTab === "notes")
                                    return notesModel.count + " notes"
                                return pinnedModel.count + " pinned"
                            }
                            color: root.mutedColor
                            font.family: root.fontFamily
                            font.pixelSize: 12
                        }
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        height: 1
                        color: root.borderColor
                    }

                    Item {
                        Layout.fillWidth: true
                        Layout.fillHeight: true

                        Text {
                            anchors.centerIn: parent
                            visible: root.loading &&
                                todoModel.count === 0 &&
                                notesModel.count === 0 &&
                                pinnedModel.count === 0
                            text: "Syncing Google Keep…"
                            color: root.mutedColor
                            font.family: root.fontFamily
                            font.pixelSize: 14
                        }

                        Text {
                            anchors.centerIn: parent
                            visible: !root.loading &&
                                root.errorMessage === "" &&
                                root.currentCount() === 0
                            text: {
                                if (root.searchText) return "No matches"
                                if (root.currentTab === "todo" && !root.todoListId)
                                    return "Your TODO note will be created when you add the first task"
                                return "Nothing here yet"
                            }
                            color: root.mutedColor
                            font.family: root.fontFamily
                            font.pixelSize: 14
                            wrapMode: Text.Wrap
                            horizontalAlignment: Text.AlignHCenter
                            width: Math.min(440, parent.width - Style.space(32))
                        }

                        ListView {
                            id: todoView
                            anchors.fill: parent
                            visible: root.currentTab === "todo"
                            model: todoModel
                            currentIndex: root.selectedTodoIndex
                            spacing: Style.space(4)
                            clip: true
                            boundsBehavior: Flickable.StopAtBounds

                            delegate: Rectangle {
                                id: todoDelegate
                                required property string itemId
                                required property string itemText
                                required property bool checked
                                required property int index

                                width: todoView.width
                                height: 48
                                radius: Style.radius(1)
                                color: index === root.selectedTodoIndex
                                    ? root.selectedColor
                                    : (todoRowMouse.containsMouse ? root.subtleColor : "transparent")
                                border.width: index === root.selectedTodoIndex ? 1 : 0
                                border.color: root.accentColor

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: Style.space(8)
                                    anchors.rightMargin: Style.space(6)
                                    spacing: Style.space(10)

                                    Rectangle {
                                        width: 19
                                        height: 19
                                        radius: 4
                                        color: checked ? root.accentColor : "transparent"
                                        border.width: checked ? 0 : 1
                                        border.color: root.mutedColor

                                        Text {
                                            anchors.centerIn: parent
                                            visible: checked
                                            text: "✓"
                                            color: root.panelColor
                                            font.family: root.fontFamily
                                            font.pixelSize: 12
                                            font.bold: true
                                        }

                                        MouseArea {
                                            anchors.fill: parent
                                            enabled: !root.mutating
                                            onClicked: {
                                                root.setCurrentSelectedIndex(todoDelegate.index)
                                                root.toggleTodo(todoDelegate.itemId, todoDelegate.checked)
                                            }
                                        }
                                    }

                                    Item {
                                        Layout.fillWidth: true
                                        Layout.fillHeight: true

                                        Text {
                                            anchors.fill: parent
                                            visible: root.editingTodoId !== todoDelegate.itemId
                                            text: todoDelegate.itemText
                                            color: checked ? root.mutedColor : root.textColor
                                            font.family: root.fontFamily
                                            font.pixelSize: 14
                                            font.strikeout: checked
                                            verticalAlignment: Text.AlignVCenter
                                            elide: Text.ElideRight
                                        }

                                        TextInput {
                                            id: todoInlineEditor
                                            anchors.fill: parent
                                            visible: root.editingTodoId === todoDelegate.itemId
                                            color: root.textColor
                                            selectionColor: root.accentColor
                                            selectedTextColor: root.panelColor
                                            font.family: root.fontFamily
                                            font.pixelSize: 14
                                            verticalAlignment: TextInput.AlignVCenter
                                            text: todoDelegate.itemText
                                            clip: true

                                            onVisibleChanged: {
                                                if (visible) {
                                                    text = todoDelegate.itemText
                                                    Qt.callLater(function() {
                                                        if (todoInlineEditor.visible) {
                                                            todoInlineEditor.forceActiveFocus()
                                                            todoInlineEditor.selectAll()
                                                        }
                                                    })
                                                }
                                            }

                                            Keys.onReturnPressed:
                                                root.saveTodoEdit(todoDelegate.itemId, text)
                                            Keys.onEnterPressed:
                                                root.saveTodoEdit(todoDelegate.itemId, text)
                                            Keys.onEscapePressed: {
                                                root.editingTodoId = ""
                                                panelKeys.forceActiveFocus()
                                            }
                                        }
                                    }

                                    Rectangle {
                                        width: 30
                                        height: 30
                                        radius: Style.radius(1)
                                        color: deleteTodoMouse.containsMouse ? root.hoverColor : "transparent"

                                        Text {
                                            anchors.centerIn: parent
                                            text: "×"
                                            color: root.mutedColor
                                            font.family: root.fontFamily
                                            font.pixelSize: 16
                                        }

                                        MouseArea {
                                            id: deleteTodoMouse
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            enabled: !root.mutating
                                            onClicked: root.deleteTodo(todoDelegate.itemId)
                                        }
                                    }
                                }

                                MouseArea {
                                    id: todoRowMouse
                                    anchors.fill: parent
                                    anchors.leftMargin: 34
                                    anchors.rightMargin: 38
                                    hoverEnabled: true
                                    enabled: root.editingTodoId !== todoDelegate.itemId
                                    onClicked: {
                                        root.setCurrentSelectedIndex(todoDelegate.index)
                                        panelKeys.forceActiveFocus()
                                    }
                                    onDoubleClicked: root.beginTodoEdit(todoDelegate.index)
                                }
                            }
                        }

                        ListView {
                            id: notesView
                            anchors.fill: parent
                            visible: root.currentTab === "notes"
                            model: notesModel
                            currentIndex: root.selectedNoteIndex
                            spacing: Style.space(7)
                            clip: true
                            boundsBehavior: Flickable.StopAtBounds

                            delegate: Rectangle {
                                id: noteDelegate
                                required property string noteId
                                required property string noteTitle
                                required property string noteText
                                required property string noteType
                                required property bool pinned
                                required property string labelsText
                                required property string previewText
                                required property int checklistTotal
                                required property int checklistDone
                                required property string itemsJson
                                required property int index

                                width: notesView.width
                                height: noteColumn.implicitHeight + Style.space(18)
                                radius: Style.radius(1)
                                color: index === root.selectedNoteIndex
                                    ? root.selectedColor
                                    : (noteMouse.containsMouse ? root.subtleColor : "transparent")
                                border.width: 1
                                border.color: index === root.selectedNoteIndex
                                    ? root.accentColor
                                    : root.borderColor

                                ColumnLayout {
                                    id: noteColumn
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.leftMargin: Style.space(10)
                                    anchors.rightMargin: Style.space(10)
                                    spacing: 5

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: Style.space(8)

                                        Text {
                                            Layout.fillWidth: true
                                            text: noteDelegate.noteTitle.trim()
                                                ? noteDelegate.noteTitle
                                                : "Untitled"
                                            color: root.textColor
                                            font.family: root.fontFamily
                                            font.pixelSize: 15
                                            font.bold: true
                                            elide: Text.ElideRight
                                        }

                                        Text {
                                            visible: noteDelegate.noteType === "list"
                                            text: noteDelegate.checklistDone + "/" + noteDelegate.checklistTotal
                                            color: root.mutedColor
                                            font.family: root.fontFamily
                                            font.pixelSize: 11
                                        }

                                        Text {
                                            visible: noteDelegate.pinned
                                            text: "◆"
                                            color: root.accentColor
                                            font.pixelSize: 10
                                        }
                                    }

                                    Text {
                                        Layout.fillWidth: true
                                        visible: noteDelegate.previewText !== ""
                                        text: noteDelegate.previewText
                                        color: root.mutedColor
                                        font.family: root.fontFamily
                                        font.pixelSize: 12
                                        maximumLineCount: noteDelegate.noteType === "list" ? 4 : 3
                                        wrapMode: Text.Wrap
                                        elide: Text.ElideRight
                                    }

                                    Text {
                                        Layout.fillWidth: true
                                        visible: noteDelegate.labelsText !== ""
                                        text: noteDelegate.labelsText
                                        color: root.mutedColor
                                        font.family: root.fontFamily
                                        font.pixelSize: 10
                                        elide: Text.ElideRight
                                    }
                                }

                                MouseArea {
                                    id: noteMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onClicked: {
                                        root.setCurrentSelectedIndex(noteDelegate.index)
                                        panelKeys.forceActiveFocus()
                                    }
                                    onDoubleClicked: root.openEditor(
                                        noteDelegate.noteId,
                                        noteDelegate.noteTitle,
                                        noteDelegate.noteText,
                                        noteDelegate.noteType,
                                        noteDelegate.pinned,
                                        noteDelegate.itemsJson
                                    )
                                }
                            }
                        }

                        ListView {
                            id: pinnedView
                            anchors.fill: parent
                            visible: root.currentTab === "pinned"
                            model: pinnedModel
                            currentIndex: root.selectedPinnedIndex
                            spacing: Style.space(7)
                            clip: true
                            boundsBehavior: Flickable.StopAtBounds

                            delegate: Rectangle {
                                id: pinnedDelegate
                                required property string noteId
                                required property string noteTitle
                                required property string noteText
                                required property string noteType
                                required property bool pinned
                                required property string labelsText
                                required property string previewText
                                required property int checklistTotal
                                required property int checklistDone
                                required property string itemsJson
                                required property int index

                                width: pinnedView.width
                                height: pinnedColumn.implicitHeight + Style.space(18)
                                radius: Style.radius(1)
                                color: index === root.selectedPinnedIndex
                                    ? root.selectedColor
                                    : (pinnedMouse.containsMouse ? root.subtleColor : "transparent")
                                border.width: 1
                                border.color: index === root.selectedPinnedIndex
                                    ? root.accentColor
                                    : root.borderColor

                                ColumnLayout {
                                    id: pinnedColumn
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.leftMargin: Style.space(10)
                                    anchors.rightMargin: Style.space(10)
                                    spacing: 5

                                    RowLayout {
                                        Layout.fillWidth: true

                                        Text {
                                            Layout.fillWidth: true
                                            text: pinnedDelegate.noteTitle.trim()
                                                ? pinnedDelegate.noteTitle
                                                : "Untitled"
                                            color: root.textColor
                                            font.family: root.fontFamily
                                            font.pixelSize: 15
                                            font.bold: true
                                            elide: Text.ElideRight
                                        }

                                        Text {
                                            visible: pinnedDelegate.noteType === "list"
                                            text: pinnedDelegate.checklistDone + "/" + pinnedDelegate.checklistTotal
                                            color: root.mutedColor
                                            font.family: root.fontFamily
                                            font.pixelSize: 11
                                        }

                                        Text {
                                            text: "◆"
                                            color: root.accentColor
                                            font.pixelSize: 10
                                        }
                                    }

                                    Text {
                                        Layout.fillWidth: true
                                        visible: pinnedDelegate.previewText !== ""
                                        text: pinnedDelegate.previewText
                                        color: root.mutedColor
                                        font.family: root.fontFamily
                                        font.pixelSize: 12
                                        maximumLineCount: pinnedDelegate.noteType === "list" ? 4 : 3
                                        wrapMode: Text.Wrap
                                        elide: Text.ElideRight
                                    }

                                    Text {
                                        Layout.fillWidth: true
                                        visible: pinnedDelegate.labelsText !== ""
                                        text: pinnedDelegate.labelsText
                                        color: root.mutedColor
                                        font.family: root.fontFamily
                                        font.pixelSize: 10
                                        elide: Text.ElideRight
                                    }
                                }

                                MouseArea {
                                    id: pinnedMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onClicked: {
                                        root.setCurrentSelectedIndex(pinnedDelegate.index)
                                        panelKeys.forceActiveFocus()
                                    }
                                    onDoubleClicked: root.openEditor(
                                        pinnedDelegate.noteId,
                                        pinnedDelegate.noteTitle,
                                        pinnedDelegate.noteText,
                                        pinnedDelegate.noteType,
                                        pinnedDelegate.pinned,
                                        pinnedDelegate.itemsJson
                                    )
                                }
                            }
                        }
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        visible: root.errorMessage !== ""
                        implicitHeight: errorText.implicitHeight + Style.space(12)
                        radius: Style.radius(1)
                        color: Qt.rgba(0.88, 0.42, 0.46, 0.12)

                        Text {
                            id: errorText
                            anchors.fill: parent
                            anchors.margins: Style.space(6)
                            text: root.errorMessage
                            color: "#e06c75"
                            font.family: root.fontFamily
                            font.pixelSize: 11
                            wrapMode: Text.Wrap
                            verticalAlignment: Text.AlignVCenter
                        }
                    }

                    Rectangle {
                        Layout.fillWidth: true
                        height: 44
                        radius: Style.radius(1)
                        color: root.subtleColor
                        border.width: captureInput.activeFocus ? 1 : 0
                        border.color: root.accentColor

                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: Style.space(8)
                            anchors.rightMargin: Style.space(8)
                            spacing: Style.space(8)

                            Rectangle {
                                height: 30
                                width: captureModeText.implicitWidth + Style.space(14)
                                radius: Style.radius(1)
                                color: captureModeMouse.containsMouse ? root.hoverColor : "transparent"

                                Text {
                                    id: captureModeText
                                    anchors.centerIn: parent
                                    text: root.captureMode === "todo"
                                        ? "✓ TODO"
                                        : (root.captureMode === "checklist" ? "☷ Checklist" : "▤ Note")
                                    color: root.textColor
                                    font.family: root.fontFamily
                                    font.pixelSize: 12
                                }

                                MouseArea {
                                    id: captureModeMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onClicked: {
                                        root.cycleCaptureMode()
                                        captureInput.forceActiveFocus()
                                    }
                                }
                            }

                            TextInput {
                                id: captureInput
                                Layout.fillWidth: true
                                color: root.textColor
                                selectionColor: root.accentColor
                                selectedTextColor: root.panelColor
                                font.family: root.fontFamily
                                font.pixelSize: 14
                                clip: true

                                Text {
                                    anchors.fill: parent
                                    visible: !captureInput.text
                                    text: root.captureMode === "todo"
                                        ? "Add to TODO…"
                                        : (root.captureMode === "checklist"
                                            ? "Create checklist note…"
                                            : "Create note…")
                                    color: root.mutedColor
                                    font.family: root.fontFamily
                                    font.pixelSize: 14
                                    verticalAlignment: Text.AlignVCenter
                                }

                                Keys.onReturnPressed: root.quickCapture()
                                Keys.onEnterPressed: root.quickCapture()
                                Keys.onEscapePressed: {
                                    captureInput.text = ""
                                    panelKeys.forceActiveFocus()
                                }
                            }

                            Text {
                                text: "↵"
                                color: root.mutedColor
                                font.family: root.fontFamily
                                font.pixelSize: 13
                            }
                        }
                    }

                    RowLayout {
                        Layout.fillWidth: true

                        Text {
                            text: "j/k move   gg/G first/last   h/l tabs   Enter open/edit   Space toggle   / search"
                            color: root.mutedColor
                            font.family: root.fontFamily
                            font.pixelSize: 10
                        }

                        Item { Layout.fillWidth: true }

                        Text {
                            text: root.mutating ? "saving…" : ""
                            color: root.mutedColor
                            font.family: root.fontFamily
                            font.pixelSize: 10
                        }
                    }
                }

                Rectangle {
                    id: authOverlay
                    anchors.fill: parent
                    visible: !root.connectionKnown || !root.connected
                    color: root.panelColor
                    z: 30

                    MouseArea {
                        anchors.fill: parent
                        onClicked: {}
                    }

                    ColumnLayout {
                        anchors.centerIn: parent
                        width: Math.min(460, authOverlay.width - Style.space(48))
                        spacing: Style.space(14)

                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            text: "Keep Notes"
                            color: root.textColor
                            font.family: root.fontFamily
                            font.pixelSize: 25
                            font.bold: true
                        }

                        Text {
                            Layout.alignment: Qt.AlignHCenter
                            visible: !root.connectionKnown
                            text: "Checking your Google Keep connection…"
                            color: root.mutedColor
                            font.family: root.fontFamily
                            font.pixelSize: 13
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: root.connectionKnown && !root.connected
                            spacing: Style.space(10)

                            Text {
                                Layout.fillWidth: true
                                text: "Connect Google Keep"
                                color: root.textColor
                                font.family: root.fontFamily
                                font.pixelSize: 18
                                font.bold: true
                                horizontalAlignment: Text.AlignHCenter
                            }

                            Text {
                                Layout.fillWidth: true
                                text: "Sign in to Google once, copy the temporary oauth_token cookie, and paste it below. Keep Notes exchanges it locally for the master token it needs."
                                color: root.mutedColor
                                font.family: root.fontFamily
                                font.pixelSize: 12
                                wrapMode: Text.Wrap
                                horizontalAlignment: Text.AlignHCenter
                            }

                            Rectangle {
                                Layout.fillWidth: true
                                implicitHeight: setupGuide.implicitHeight + Style.space(16)
                                radius: Style.radius(1)
                                color: root.subtleColor
                                border.width: 1
                                border.color: root.borderColor

                                ColumnLayout {
                                    id: setupGuide
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    anchors.leftMargin: Style.space(10)
                                    anchors.rightMargin: Style.space(10)
                                    spacing: Style.space(6)

                                    Text {
                                        Layout.fillWidth: true
                                        text: "1. Open Google sign-in and log in. Press “I agree” if Google asks."
                                        color: root.textColor
                                        font.family: root.fontFamily
                                        font.pixelSize: 11
                                        wrapMode: Text.Wrap
                                    }

                                    Text {
                                        Layout.fillWidth: true
                                        text: "2. Open DevTools → Application → Cookies → accounts.google.com."
                                        color: root.textColor
                                        font.family: root.fontFamily
                                        font.pixelSize: 11
                                        wrapMode: Text.Wrap
                                    }

                                    Text {
                                        Layout.fillWidth: true
                                        text: "3. Copy the value of the oauth_token cookie and paste it below. Use it immediately; it is short-lived and single-use."
                                        color: root.textColor
                                        font.family: root.fontFamily
                                        font.pixelSize: 11
                                        wrapMode: Text.Wrap
                                    }

                                    Rectangle {
                                        Layout.fillWidth: true
                                        height: 36
                                        radius: Style.radius(1)
                                        color: setupButtonMouse.containsMouse
                                            ? root.hoverColor
                                            : "transparent"
                                        border.width: 1
                                        border.color: root.borderColor

                                        Text {
                                            anchors.centerIn: parent
                                            text: "Open Google Sign-in"
                                            color: root.textColor
                                            font.family: root.fontFamily
                                            font.pixelSize: 12
                                            font.bold: true
                                        }

                                        MouseArea {
                                            id: setupButtonMouse
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            onClicked: root.openGoogleSetup()
                                        }
                                    }
                                }
                            }

                            Text {
                                text: "Email"
                                color: root.mutedColor
                                font.family: root.fontFamily
                                font.pixelSize: 11
                            }

                            Rectangle {
                                Layout.fillWidth: true
                                height: 44
                                radius: Style.radius(1)
                                color: root.subtleColor
                                border.width: authEmail.activeFocus ? 1 : 0
                                border.color: root.accentColor

                                TextInput {
                                    id: authEmail
                                    anchors.fill: parent
                                    anchors.leftMargin: Style.space(10)
                                    anchors.rightMargin: Style.space(10)
                                    color: root.textColor
                                    selectionColor: root.accentColor
                                    selectedTextColor: root.panelColor
                                    font.family: root.fontFamily
                                    font.pixelSize: 14
                                    verticalAlignment: TextInput.AlignVCenter
                                    clip: true
                                    inputMethodHints: Qt.ImhEmailCharactersOnly | Qt.ImhNoAutoUppercase

                                    Text {
                                        anchors.fill: parent
                                        visible: !authEmail.text
                                        text: "you@gmail.com"
                                        color: root.mutedColor
                                        font.family: root.fontFamily
                                        font.pixelSize: 14
                                        verticalAlignment: Text.AlignVCenter
                                    }

                                    Keys.onReturnPressed: authToken.forceActiveFocus()
                                    Keys.onEnterPressed: authToken.forceActiveFocus()
                                    Keys.onEscapePressed: root.dismiss()
                                }
                            }

                            Text {
                                text: "Temporary oauth_token cookie"
                                color: root.mutedColor
                                font.family: root.fontFamily
                                font.pixelSize: 11
                            }

                            Rectangle {
                                Layout.fillWidth: true
                                height: 44
                                radius: Style.radius(1)
                                color: root.subtleColor
                                border.width: authToken.activeFocus ? 1 : 0
                                border.color: root.accentColor

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: Style.space(10)
                                    anchors.rightMargin: Style.space(6)
                                    spacing: Style.space(6)

                                    TextInput {
                                        id: authToken
                                        Layout.fillWidth: true
                                        color: root.textColor
                                        selectionColor: root.accentColor
                                        selectedTextColor: root.panelColor
                                        font.family: root.fontFamily
                                        font.pixelSize: 14
                                        verticalAlignment: TextInput.AlignVCenter
                                        clip: true
                                        echoMode: root.authTokenVisible
                                            ? TextInput.Normal
                                            : TextInput.Password

                                        Text {
                                            anchors.fill: parent
                                            visible: !authToken.text
                                            text: "oauth2_4/…"
                                            color: root.mutedColor
                                            font.family: root.fontFamily
                                            font.pixelSize: 14
                                            verticalAlignment: Text.AlignVCenter
                                        }

                                        Keys.onReturnPressed: root.startAuthentication()
                                        Keys.onEnterPressed: root.startAuthentication()
                                        Keys.onEscapePressed: root.dismiss()
                                    }

                                    Rectangle {
                                        width: 34
                                        height: 32
                                        radius: Style.radius(1)
                                        color: authTokenRevealMouse.containsMouse
                                            ? root.hoverColor
                                            : "transparent"

                                        Text {
                                            anchors.centerIn: parent
                                            text: root.authTokenVisible ? "◉" : "○"
                                            color: root.mutedColor
                                            font.family: root.fontFamily
                                            font.pixelSize: 14
                                        }

                                        MouseArea {
                                            id: authTokenRevealMouse
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            onClicked: root.authTokenVisible = !root.authTokenVisible
                                        }
                                    }
                                }
                            }

                            Text {
                                Layout.fillWidth: true
                                visible: root.authError !== ""
                                text: root.authError
                                color: "#e06c75"
                                font.family: root.fontFamily
                                font.pixelSize: 11
                                wrapMode: Text.Wrap
                            }

                            Rectangle {
                                Layout.fillWidth: true
                                height: 42
                                radius: Style.radius(1)
                                color: connectMouse.containsMouse
                                    ? Qt.lighter(root.accentColor, 1.08)
                                    : root.accentColor

                                Text {
                                    anchors.centerIn: parent
                                    text: root.authenticating ? "Connecting…" : "Connect & Sync"
                                    color: root.panelColor
                                    font.family: root.fontFamily
                                    font.pixelSize: 13
                                    font.bold: true
                                }

                                MouseArea {
                                    id: connectMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    enabled: !root.authenticating
                                    onClicked: root.startAuthentication()
                                }
                            }

                            Text {
                                Layout.fillWidth: true
                                text: "The temporary oauth_token is never stored. Keep Notes exchanges it locally and stores only the resulting master token in ~/.local/state/keep-notes/credentials.json with private permissions."
                                color: root.mutedColor
                                font.family: root.fontFamily
                                font.pixelSize: 10
                                wrapMode: Text.Wrap
                                horizontalAlignment: Text.AlignHCenter
                            }
                        }
                    }
                }

                Rectangle {
                    id: editor
                    anchors.fill: parent
                    visible: root.editorOpen
                    color: root.panelColor
                    z: 10
                    focus: root.editorOpen

                    Keys.onEscapePressed: {
                        if (editorTitle.activeFocus ||
                            editorBody.activeFocus ||
                            editorNewItem.activeFocus) {
                            editor.forceActiveFocus()
                        } else {
                            root.editorOpen = false
                            editorItemsModel.clear()
                            panelKeys.forceActiveFocus()
                        }
                    }

                    Keys.onPressed: function(event) {
                        if (!root.editorOpen)
                            return

                        if (root.editorType === "list") {
                            if (event.key === Qt.Key_J || event.key === Qt.Key_Down) {
                                root.moveEditorSelection(1)
                                event.accepted = true
                            } else if (event.key === Qt.Key_K || event.key === Qt.Key_Up) {
                                root.moveEditorSelection(-1)
                                event.accepted = true
                            } else if (event.key === Qt.Key_Space || event.key === Qt.Key_X) {
                                root.toggleEditorSelectedItem()
                                event.accepted = true
                            } else if (event.key === Qt.Key_D) {
                                root.deleteEditorSelectedItem()
                                event.accepted = true
                            } else if (event.key === Qt.Key_Return ||
                                       event.key === Qt.Key_Enter ||
                                       event.key === Qt.Key_E) {
                                root.focusEditorItem(root.editorSelectedIndex >= 0
                                    ? root.editorSelectedIndex
                                    : 0)
                                event.accepted = true
                            } else if (event.key === Qt.Key_A) {
                                editorNewItem.forceActiveFocus()
                                event.accepted = true
                            } else if (event.key === Qt.Key_T) {
                                editorTitle.forceActiveFocus()
                                event.accepted = true
                            }
                        } else {
                            if (event.key === Qt.Key_Return ||
                                event.key === Qt.Key_Enter ||
                                event.key === Qt.Key_I ||
                                event.key === Qt.Key_J ||
                                event.key === Qt.Key_Down) {
                                editorBody.forceActiveFocus()
                                event.accepted = true
                            } else if (event.key === Qt.Key_T ||
                                       event.key === Qt.Key_K ||
                                       event.key === Qt.Key_Up) {
                                editorTitle.forceActiveFocus()
                                event.accepted = true
                            }
                        }
                    }

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: Style.space(16)
                        spacing: Style.space(12)

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: Style.space(8)

                            Rectangle {
                                width: 34
                                height: 30
                                radius: Style.radius(1)
                                color: backMouse.containsMouse ? root.hoverColor : "transparent"

                                Text {
                                    anchors.centerIn: parent
                                    text: "←"
                                    color: root.textColor
                                    font.family: root.fontFamily
                                    font.pixelSize: 18
                                }

                                MouseArea {
                                    id: backMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    onClicked: {
                                        root.editorOpen = false
                                        editorItemsModel.clear()
                                        panelKeys.forceActiveFocus()
                                    }
                                }
                            }

                            Text {
                                text: root.editorType === "list" ? "Checklist" : "Note"
                                color: root.textColor
                                font.family: root.fontFamily
                                font.pixelSize: 18
                                font.bold: true
                            }

                            Item { Layout.fillWidth: true }

                            Rectangle {
                                width: pinButtonLabel.implicitWidth + Style.space(16)
                                height: 30
                                radius: Style.radius(1)
                                color: pinButtonMouse.containsMouse ? root.hoverColor : "transparent"

                                Text {
                                    id: pinButtonLabel
                                    anchors.centerIn: parent
                                    text: root.editorPinned ? "Unpin" : "Pin"
                                    color: root.editorPinned ? root.accentColor : root.textColor
                                    font.family: root.fontFamily
                                    font.pixelSize: 12
                                }

                                MouseArea {
                                    id: pinButtonMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    enabled: !root.mutating && !root.loading
                                    onClicked: root.toggleEditorPin()
                                }
                            }

                            Rectangle {
                                width: archiveLabel.implicitWidth + Style.space(16)
                                height: 30
                                radius: Style.radius(1)
                                color: archiveMouse.containsMouse ? root.hoverColor : "transparent"

                                Text {
                                    id: archiveLabel
                                    anchors.centerIn: parent
                                    text: "Archive"
                                    color: root.mutedColor
                                    font.family: root.fontFamily
                                    font.pixelSize: 12
                                }

                                MouseArea {
                                    id: archiveMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    enabled: !root.mutating && !root.loading
                                    onClicked: root.archiveEditor()
                                }
                            }
                        }

                        Text {
                            text: "Title"
                            color: root.mutedColor
                            font.family: root.fontFamily
                            font.pixelSize: 11
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            height: 48
                            radius: Style.radius(1)
                            color: root.subtleColor
                            border.width: editorTitle.activeFocus ? 1 : 0
                            border.color: root.accentColor

                            TextInput {
                                id: editorTitle
                                anchors.fill: parent
                                anchors.leftMargin: Style.space(10)
                                anchors.rightMargin: Style.space(10)
                                color: root.textColor
                                selectionColor: root.accentColor
                                selectedTextColor: root.panelColor
                                font.family: root.fontFamily
                                font.pixelSize: 18
                                font.bold: true
                                verticalAlignment: TextInput.AlignVCenter
                                clip: true

                                Keys.onTabPressed: root.focusEditorBody()
                                Keys.onDownPressed: root.focusEditorBody()
                                Keys.onEscapePressed: editor.forceActiveFocus()
                            }
                        }

                        Item {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: root.editorType === "text"

                            Rectangle {
                                anchors.fill: parent
                                radius: Style.radius(1)
                                color: root.subtleColor
                                border.width: editorBody.activeFocus ? 1 : 0
                                border.color: root.accentColor

                                TextEdit {
                                    id: editorBody
                                    anchors.fill: parent
                                    anchors.margins: Style.space(10)
                                    color: root.textColor
                                    selectionColor: root.accentColor
                                    selectedTextColor: root.panelColor
                                    font.family: root.fontFamily
                                    font.pixelSize: 14
                                    wrapMode: TextEdit.Wrap
                                    clip: true

                                    Keys.onBacktabPressed: editorTitle.forceActiveFocus()
                                    Keys.onEscapePressed: editor.forceActiveFocus()
                                }
                            }
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            visible: root.editorType === "list"
                            spacing: Style.space(8)

                            Text {
                                text: "Items"
                                color: root.mutedColor
                                font.family: root.fontFamily
                                font.pixelSize: 11
                            }

                            ListView {
                                id: editorItemsView
                                Layout.fillWidth: true
                                Layout.fillHeight: true
                                model: editorItemsModel
                                currentIndex: root.editorSelectedIndex
                                spacing: Style.space(4)
                                clip: true
                                boundsBehavior: Flickable.StopAtBounds

                                delegate: Rectangle {
                                    id: editorItemDelegate
                                    required property string itemId
                                    required property string itemText
                                    required property bool checked
                                    required property int index

                                    width: editorItemsView.width
                                    height: 42
                                    radius: Style.radius(1)
                                    color: index === root.editorSelectedIndex
                                        ? root.selectedColor
                                        : root.subtleColor
                                    border.width: index === root.editorSelectedIndex ? 1 : 0
                                    border.color: root.accentColor

                                    function focusText() {
                                        root.setEditorSelectedIndex(index)
                                        editorItemText.forceActiveFocus()
                                        editorItemText.selectAll()
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        onClicked: {
                                            root.setEditorSelectedIndex(editorItemDelegate.index)
                                            editor.forceActiveFocus()
                                        }
                                    }

                                    RowLayout {
                                        anchors.fill: parent
                                        anchors.leftMargin: Style.space(8)
                                        anchors.rightMargin: Style.space(6)
                                        spacing: Style.space(8)

                                        Rectangle {
                                            width: 18
                                            height: 18
                                            radius: 4
                                            color: editorItemDelegate.checked
                                                ? root.accentColor
                                                : "transparent"
                                            border.width: editorItemDelegate.checked ? 0 : 1
                                            border.color: root.mutedColor

                                            Text {
                                                anchors.centerIn: parent
                                                visible: editorItemDelegate.checked
                                                text: "✓"
                                                color: root.panelColor
                                                font.family: root.fontFamily
                                                font.pixelSize: 12
                                                font.bold: true
                                            }

                                            MouseArea {
                                                anchors.fill: parent
                                                onClicked: editorItemsModel.setProperty(
                                                    editorItemDelegate.index,
                                                    "checked",
                                                    !editorItemDelegate.checked
                                                )
                                            }
                                        }

                                        TextInput {
                                            id: editorItemText
                                            Layout.fillWidth: true
                                            text: editorItemDelegate.itemText
                                            color: root.textColor
                                            selectionColor: root.accentColor
                                            selectedTextColor: root.panelColor
                                            font.family: root.fontFamily
                                            font.pixelSize: 13
                                            clip: true

                                            onTextChanged: {
                                                if (text !== editorItemDelegate.itemText)
                                                    editorItemsModel.setProperty(
                                                        editorItemDelegate.index,
                                                        "itemText",
                                                        text
                                                    )
                                            }

                                            Keys.onEscapePressed: editor.forceActiveFocus()

                                            Keys.onDownPressed: {
                                                if (editorItemDelegate.index + 1 < editorItemsModel.count)
                                                    root.focusEditorItem(editorItemDelegate.index + 1)
                                                else
                                                    editorNewItem.forceActiveFocus()
                                            }

                                            Keys.onUpPressed: {
                                                if (editorItemDelegate.index > 0)
                                                    root.focusEditorItem(editorItemDelegate.index - 1)
                                                else
                                                    editorTitle.forceActiveFocus()
                                            }

                                            Keys.onTabPressed: {
                                                if (editorItemDelegate.index + 1 < editorItemsModel.count)
                                                    root.focusEditorItem(editorItemDelegate.index + 1)
                                                else
                                                    editorNewItem.forceActiveFocus()
                                            }

                                            Keys.onBacktabPressed: {
                                                if (editorItemDelegate.index > 0)
                                                    root.focusEditorItem(editorItemDelegate.index - 1)
                                                else
                                                    editorTitle.forceActiveFocus()
                                            }

                                            Keys.onPressed: function(event) {
                                                if ((event.modifiers & Qt.ControlModifier) &&
                                                    event.key === Qt.Key_Space) {
                                                    editorItemsModel.setProperty(
                                                        editorItemDelegate.index,
                                                        "checked",
                                                        !editorItemDelegate.checked
                                                    )
                                                    event.accepted = true
                                                } else if ((event.modifiers & Qt.ControlModifier) &&
                                                           event.key === Qt.Key_D) {
                                                    root.setEditorSelectedIndex(editorItemDelegate.index)
                                                    root.deleteEditorSelectedItem()
                                                    editor.forceActiveFocus()
                                                    event.accepted = true
                                                }
                                            }
                                        }

                                        Rectangle {
                                            width: 28
                                            height: 28
                                            radius: Style.radius(1)
                                            color: removeItemMouse.containsMouse ? root.hoverColor : "transparent"

                                            Text {
                                                anchors.centerIn: parent
                                                text: "×"
                                                color: root.mutedColor
                                                font.family: root.fontFamily
                                                font.pixelSize: 15
                                            }

                                            MouseArea {
                                                id: removeItemMouse
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                onClicked: editorItemsModel.remove(editorItemDelegate.index)
                                            }
                                        }
                                    }
                                }
                            }

                            Rectangle {
                                Layout.fillWidth: true
                                height: 40
                                radius: Style.radius(1)
                                color: root.subtleColor
                                border.width: editorNewItem.activeFocus ? 1 : 0
                                border.color: root.accentColor

                                RowLayout {
                                    anchors.fill: parent
                                    anchors.leftMargin: Style.space(10)
                                    anchors.rightMargin: Style.space(10)
                                    spacing: Style.space(8)

                                    Text {
                                        text: "+"
                                        color: root.mutedColor
                                        font.family: root.fontFamily
                                        font.pixelSize: 17
                                    }

                                    TextInput {
                                        id: editorNewItem
                                        Layout.fillWidth: true
                                        color: root.textColor
                                        selectionColor: root.accentColor
                                        selectedTextColor: root.panelColor
                                        font.family: root.fontFamily
                                        font.pixelSize: 13

                                        Text {
                                            anchors.fill: parent
                                            visible: !editorNewItem.text
                                            text: "Add checklist item…"
                                            color: root.mutedColor
                                            font.family: root.fontFamily
                                            font.pixelSize: 13
                                            verticalAlignment: Text.AlignVCenter
                                        }

                                        Keys.onReturnPressed: root.addEditorItem()
                                        Keys.onEnterPressed: root.addEditorItem()
                                        Keys.onUpPressed: {
                                            if (editorItemsModel.count > 0)
                                                root.focusEditorItem(editorItemsModel.count - 1)
                                            else
                                                editorTitle.forceActiveFocus()
                                        }
                                        Keys.onBacktabPressed: {
                                            if (editorItemsModel.count > 0)
                                                root.focusEditorItem(editorItemsModel.count - 1)
                                            else
                                                editorTitle.forceActiveFocus()
                                        }
                                        Keys.onEscapePressed: editor.forceActiveFocus()
                                    }
                                }
                            }
                        }

                        RowLayout {
                            Layout.fillWidth: true

                            Text {
                                text: root.editorType === "list"
                                    ? "Esc normal mode · j/k move · Space/x check · d delete · Enter/e edit · a add · t title"
                                    : "Tab/↓ title → body · Shift+Tab body → title · Esc normal mode"
                                color: root.mutedColor
                                font.family: root.fontFamily
                                font.pixelSize: 10
                            }

                            Item { Layout.fillWidth: true }

                            Rectangle {
                                width: 88
                                height: 34
                                radius: Style.radius(1)
                                color: saveMouse.containsMouse
                                    ? Qt.lighter(root.accentColor, 1.08)
                                    : root.accentColor

                                Text {
                                    anchors.centerIn: parent
                                    text: root.mutating ? "Saving…" : "Save"
                                    color: root.panelColor
                                    font.family: root.fontFamily
                                    font.pixelSize: 13
                                    font.bold: true
                                }

                                MouseArea {
                                    id: saveMouse
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    enabled: !root.mutating && !root.loading
                                    onClicked: root.saveEditor()
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
