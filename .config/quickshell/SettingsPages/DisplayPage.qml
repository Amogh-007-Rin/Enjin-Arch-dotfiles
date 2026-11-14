import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import "../"

Item {
    id: page

    property var monitors: []
    property var savedState: ({})
    // Name of the monitor the user picked as MAIN. Stored separately from the layout, so
    // changing it never moves a monitor and moving a monitor never un-sets it.
    property string mainName: ""
    // Raw hyprctl JSON of the last refresh; an unchanged refresh skips rebuilding every delegate.
    property string lastMonitorsJson: ""
    property real marginLeft: 0
    property real marginRight: 10
    property real marginTop: 0
    property real marginBottom: 0
    // Slider bounds only. Hyprland's own scale limits were not verified.
    property real scaleMin: 0.5
    property real scaleMax: 3.0
    readonly property string stateDir: Quickshell.env("HOME") + "/.config/quickshell/state"
    readonly property var activeMonitors: monitors.filter(m => !m.disabled)

    // The monitor shown as MAIN: the saved choice if it is still active, otherwise the
    // monitor at 0x0 (the old behaviour), otherwise the first active one.
    readonly property string effectiveMainName: {
        const act = activeMonitors
        if (act.length === 0) return ""
        if (mainName !== "" && act.some(m => m.name === mainName)) return mainName
        const origin = act.find(m => m.x === 0 && m.y === 0)
        return origin ? origin.name : act[0].name
    }

    readonly property string displayMode: {
        const act = activeMonitors
        if (act.length < 2) return act.length === 1 ? "SINGLE" : "NONE"
        const runtimeMirror = act.some(m => typeof m.mirrorOf === "string" && m.mirrorOf !== "")
        const savedMirror = act.some(m => savedState[m.name] && savedState[m.name].mirror)
        return runtimeMirror || savedMirror ? "MIRRORED" : "EXTENDED"
    }

    Process {
        id: stateDirProcess
        command: ["mkdir", "-p", page.stateDir]
    }

    FileView {
        id: displayFile
        path: page.stateDir + "/display.json"
        blockLoading: true
    }

    FileView {
        id: displayLua
        path: page.stateDir + "/display.lua"
    }

    function loadState() {
        try {
            const saved = JSON.parse(displayFile.text())
            if (saved && typeof saved.monitors === "object" && saved.monitors !== null) {
                savedState = saved.monitors
            }
            if (saved && typeof saved.main === "string") mainName = saved.main
        } catch (error) {}

        // Rewrite stale scales (e.g. an old rounded 1.06) that would trigger "Invalid scale".
        let dirty = false
        const fixed = {}
        for (const name of Object.keys(savedState)) {
            const e = Object.assign({}, savedState[name])
            if (typeof e.mode === "string" && typeof e.scale === "number") {
                const s = scaleForMode(e.mode, null, e.scale)
                if (Math.abs(s - e.scale) > 1e-9) { e.scale = s; dirty = true }
            }
            fixed[name] = e
        }
        if (dirty) { savedState = fixed; stateSaveTimer.restart() }
    }

    function luaFileText() {
        const lines = []
        const names = Object.keys(savedState)

        // The monitor module uses these names to keep workspace groups separate:
        // workspaces 1-4 follow MONITOR1 and 5-6 follow MONITOR2.
        const activeNames = names.filter(name => {
            const entry = savedState[name]
            return entry && entry.disabled !== true && typeof entry.mode === "string"
        })
        const monitor1 = mainName !== "" && activeNames.indexOf(mainName) !== -1
            ? mainName : (activeNames.length > 0 ? activeNames[0] : "")
        const monitor2 = activeNames.find(name => name !== monitor1) || ""
        lines.push("MONITOR1 = " + (monitor1 === "" ? "nil" : "\"" + luaString(monitor1) + "\""))
        lines.push("MONITOR2 = " + (monitor2 === "" ? "nil" : "\"" + luaString(monitor2) + "\""))

        for (let i = 0; i < names.length; i++) {
            const entry = savedState[names[i]]
            if (!entry) continue
            if (entry.disabled === true) {
                lines.push(monitorLua({ name: names[i] }, { disabled: true }))
                continue
            }
            if (typeof entry.mode !== "string") continue
            lines.push(monitorLua({ name: names[i] }, {
                mode: entry.mode,
                position: typeof entry.position === "string" ? entry.position : "auto",
                scale: typeof entry.scale === "number" ? scaleForMode(entry.mode, null, entry.scale) : 1,
                transform: typeof entry.transform === "number" ? entry.transform : 0,
                mirror: typeof entry.mirror === "string" ? entry.mirror : "",
                disabled: false
            }))
        }
        return lines.join("\n") + "\n"
    }

    function saveStateNow() {
        try {
            displayFile.setText(JSON.stringify({ monitors: page.savedState, main: page.mainName }, null, 2))
            displayLua.setText(page.luaFileText())
        } catch (error) {}
    }

    Timer {
        id: stateSaveTimer
        interval: 300
        onTriggered: page.saveStateNow()
    }

    function monitorPosition(mon) {
        return page.activeMonitors.length <= 1 ? "auto" : mon.x + "x" + mon.y
    }

    function rememberMonitor(mon, fields) {
        if (!mon || !mon.name) return
        const base = typeof mon.transform === "number" ? { transform: mon.transform } : {}
        const next = Object.assign({}, savedState)
        next[mon.name] = Object.assign({}, next[mon.name] || {}, base, fields)
        savedState = next
        stateSaveTimer.restart()
    }

    Process {
        id: pReset
        onExited: exitCode => {
            refreshTimer.restart()
            lateRefreshTimer.restart()
        }
    }

    function resetToConfig() {
        if (pShell.running) return
        stateSaveTimer.stop()
        savedState = ({})
        mainName = ""
        pReset.command = [
            "sh", "-c",
            "rm -f '" + page.stateDir + "/display.json' '" + page.stateDir + "/display.lua'; hyprctl reload"
        ]
        pReset.running = true
    }

    function monitorMode(mon) { return mon.width + "x" + mon.height + "@" + mon.refreshRate.toFixed(2) }

    function luaString(value) { return String(value).replace(/\\/g, "\\\\").replace(/"/g, "\\\"") }

    function monitorLua(mon, options = {}) {
        const values = ["output = \"" + luaString(mon.name) + "\""]
        if (options.mode !== undefined) values.push("mode = \"" + luaString(options.mode) + "\"")
        if (options.position !== undefined) values.push("position = \"" + luaString(options.position) + "\"")
        if (options.scale !== undefined) values.push("scale = " + options.scale)
        // Hyprland resets transform to 0 when a rule omits it, so always send the current one with a mode.
        const transform = options.transform !== undefined
            ? options.transform
            : (options.mode !== undefined && typeof mon.transform === "number" ? mon.transform : undefined)
        if (transform !== undefined) values.push("transform = " + transform)
        if (options.disabled !== undefined) values.push("disabled = " + options.disabled)
        const mirror = options.mirror !== undefined
            ? options.mirror
            : (savedState[mon.name] && savedState[mon.name].mirror ? savedState[mon.name].mirror : "")
        if (mirror !== "") values.push("mirror = \"" + luaString(mirror) + "\"")
        return "hl.monitor({" + values.join(",") + "})"
    }

    function isMain(mon) {
        return !mon.disabled && mon.name === page.effectiveMainName
    }

    // Logs hyprctl output so failed rules are visible in the quickshell terminal,
    // and refreshes twice because a re-enabled monitor needs a moment to modeset.
    Process {
        id: pShell
        property var rollbackState: null
        property string rollbackMainName: ""
        stdout: StdioCollector {
            onStreamFinished: if (text.trim().length > 0) console.log("[display] hyprctl:", text.trim())
        }
        stderr: StdioCollector {
            onStreamFinished: if (text.trim().length > 0) console.warn("[display] hyprctl error:", text.trim())
        }
        onExited: exitCode => {
            if (exitCode !== 0 && pShell.rollbackState !== null) {
                // Do not leave the settings file claiming a mode that Hyprland rejected.
                // The next toggle will start from the actual monitor layout after refresh.
                page.savedState = pShell.rollbackState
                page.mainName = pShell.rollbackMainName
                stateSaveTimer.restart()
                console.warn("[display] monitor layout change failed; restored previous saved layout")
            }
            pShell.rollbackState = null
            pShell.rollbackMainName = ""
            refreshTimer.restart()
            lateRefreshTimer.restart()
        }
    }

    function runShell(cmds, rollbackState = null, rollbackMainName = "") {
        // A monitor modeset is asynchronous. Ignore repeated clicks until the
        // compositor has reported the result, instead of replacing a half-run command.
        if (cmds.length === 0 || pShell.running) return false
        pShell.rollbackState = rollbackState
        pShell.rollbackMainName = rollbackMainName
        pShell.command = ["sh", "-c", "set -e; " + cmds.join("; ")]
        pShell.running = true
        return true
    }

    // Hyprland applies each rule immediately, so any intermediate step that lands a monitor
    // on top of another one triggers the "monitor layout is set up incorrectly" warning.
    // With 2+ monitors, first park them all to the right of the current layout, then place
    // them at their final positions. Nothing overlaps at any step.
    // Valid scales give whole logical sizes; the small tolerance only absorbs float noise
    // from the scale reported by hyprctl, while Math.ceil still protects against real
    // sub-pixel overlap.
    // Transforms 1 and 3 (and 5 and 7) rotate by 90 degrees, which swaps width and height.
    function swapsAxes(t) { return (t & 1) === 1 }
    function logicalWidthFor(mon, t) {
        return Math.ceil((swapsAxes(t) ? mon.height : mon.width) / mon.scale - 0.01)
    }
    function logicalHeightFor(mon, t) {
        return Math.ceil((swapsAxes(t) ? mon.width : mon.height) / mon.scale - 0.01)
    }
    function logicalWidth(mon) { return logicalWidthFor(mon, mon.transform || 0) }
    function logicalHeight(mon) { return logicalHeightFor(mon, mon.transform || 0) }

    function parsePosition(value) {
        const match = String(value || "").match(/^(-?\d+)x(-?\d+)$/)
        return match ? { x: parseInt(match[1]), y: parseInt(match[2]) } : null
    }

    function positionString(x, y) { return x + "x" + y }

    // Park all monitors before applying their final positions. This keeps the
    // transition safe even when the target geometry is above, below, or to the
    // left of the laptop instead of the default left-to-right arrangement.
    function layoutCommands(ordered, targetPositions = null) {
        const cmds = []

        if (ordered.length > 1) {
            let parkX = 0
            for (let i = 0; i < ordered.length; i++)
                parkX = Math.max(parkX, ordered[i].x + logicalWidth(ordered[i]) + 1)
            parkX = Math.max(parkX, 1)
            for (let i = 0; i < ordered.length; i++) {
                const m = ordered[i]
                cmds.push("hyprctl eval '" + monitorLua(m, { mode: monitorMode(m), position: parkX + "x0", scale: fixedScale(m), mirror: "" }) + "'")
                parkX += logicalWidth(m)
            }
        }

        let x = 0
        for (let i = 0; i < ordered.length; i++) {
            const m = ordered[i]
            const mode = monitorMode(m)
            const requested = targetPositions && targetPositions[m.name]
            const pos = requested ? positionString(requested.x, requested.y) : x + "x0"
            rememberMonitor(m, {
                mode: mode, scale: fixedScale(m), position: pos,
                extendedPosition: pos, mirror: "", disabled: false
            })
            cmds.push("hyprctl eval '" + monitorLua(m, { mode: mode, position: pos, scale: fixedScale(m), mirror: "" }) + "'")
            x += logicalWidth(m)
        }
        if (ordered.length > 0) cmds.push("hyprctl dispatch focusmonitor '" + ordered[0].name + "'")
        return cmds
    }

    function setDisplayMode(mode) {
        if (pShell.running) return
        const active = page.activeMonitors.slice().sort((a, b) => a.x - b.x || a.y - b.y)
        if (active.length < 2 || (mode !== "mirror" && mode !== "extend")) return

        const previousState = savedState
        const previousMainName = mainName
        const main = active.find(m => m.name === page.effectiveMainName) || active[0]
        const others = active.filter(m => m.name !== main.name)
        mainName = main.name

        if (mode === "extend") {
            // Restore each monitor's last extended position. If no position was
            // saved (for example after an old config), fall back to left-to-right.
            const targetPositions = {}
            const ordered = [main].concat(others)
            let validSavedLayout = true
            for (let i = 0; i < ordered.length; i++) {
                const entry = savedState[ordered[i].name]
                const saved = entry && parsePosition(entry.extendedPosition)
                if (!saved) { validSavedLayout = false; break }
                targetPositions[ordered[i].name] = saved
            }
            const commands = layoutCommands(ordered, validSavedLayout ? targetPositions : null)
            saveStateNow()
            runShell(commands, previousState, previousMainName)
            return
        }

        const cmds = []
        const mainMode = monitorMode(main)
        const mainScale = fixedScale(main)
        const extendedPositions = {}
        const extendedMonitors = [main].concat(others)
        for (let i = 0; i < extendedMonitors.length; i++) {
            const mon = extendedMonitors[i]
            const entry = savedState[mon.name]
            // Do not overwrite the remembered extended geometry if this is
            // already mirrored and all runtime positions are necessarily 0x0.
            extendedPositions[mon.name] = page.displayMode !== "MIRRORED"
                ? positionString(mon.x, mon.y)
                : ((entry && parsePosition(entry.extendedPosition)) || { x: mon.x, y: mon.y })
        }
        rememberMonitor(main, {
            mode: mainMode, scale: mainScale, position: "0x0",
            extendedPosition: positionString(extendedPositions[main.name].x, extendedPositions[main.name].y),
            mirror: "", disabled: false
        })
        cmds.push("hyprctl eval '" + monitorLua(main, {
            mode: mainMode, position: "0x0", scale: mainScale, mirror: ""
        }) + "'")

        for (let i = 0; i < others.length; i++) {
            const mon = others[i]
            const modeName = monitorMode(mon)
            const scale = fixedScale(mon)
            rememberMonitor(mon, {
                mode: modeName, scale: scale, position: "0x0",
                extendedPosition: positionString(extendedPositions[mon.name].x, extendedPositions[mon.name].y),
                mirror: main.name, disabled: false
            })
            cmds.push("hyprctl eval '" + monitorLua(mon, {
                mode: modeName, position: "0x0", scale: scale, mirror: main.name
            }) + "'")
        }

        cmds.push("hyprctl dispatch focusmonitor '" + main.name + "'")
        saveStateNow()
        runShell(cmds, previousState, previousMainName)
    }

    // MAIN is a preference, not a position: the layout is left exactly as the user arranged it.
    // (The old code moved the monitor to 0x0 and pushed the others to its right, which is why
    // the HDMI monitor jumped to the left; and since MAIN was derived from x/y == 0, moving it
    // anywhere else made MAIN disappear.)
    function setMainMonitor(main) {
        if (pShell.running || !main || !main.name || main.disabled) return
        mainName = main.name
        stateSaveTimer.restart()
        runShell(["hyprctl dispatch focusmonitor '" + main.name + "'"])
    }

    // Which side of `ref` the monitor `mon` currently touches ("" when none).
    function relation(mon, ref) {
        if (!mon || !ref || mon.name === ref.name) return ""
        if (mon.x + logicalWidth(mon) === ref.x) return "left"
        if (mon.x === ref.x + logicalWidth(ref)) return "right"
        if (mon.y + logicalHeight(mon) === ref.y) return "above"
        if (mon.y === ref.y + logicalHeight(ref)) return "below"
        return ""
    }

    // Place `mon` against `ref` on the given side (top/left edges aligned), then shift the
    // whole layout so the top-left monitor sits at 0x0. Only monitors whose position
    // actually changes are touched; if several change they are parked to the right first.
    function placeMonitor(mon, ref, side) {
        if (pShell.running || page.displayMode === "MIRRORED" || !mon || !ref || mon.name === ref.name || mon.disabled || ref.disabled) return

        let x = ref.x
        let y = ref.y
        if (side === "left") x = ref.x - logicalWidth(mon)
        else if (side === "right") x = ref.x + logicalWidth(ref)
        else if (side === "above") y = ref.y - logicalHeight(mon)
        else if (side === "below") y = ref.y + logicalHeight(ref)
        else return

        const layout = page.activeMonitors.map(m => ({
            mon: m,
            x: m.name === mon.name ? x : m.x,
            y: m.name === mon.name ? y : m.y
        }))

        let minX = Infinity
        let minY = Infinity
        for (let i = 0; i < layout.length; i++) {
            minX = Math.min(minX, layout[i].x)
            minY = Math.min(minY, layout[i].y)
        }

        const changed = []
        let parkX = 0
        for (let i = 0; i < layout.length; i++) {
            const l = layout[i]
            l.x -= minX
            l.y -= minY
            parkX = Math.max(parkX, l.x + logicalWidth(l.mon))
            if (l.x !== l.mon.x || l.y !== l.mon.y) changed.push(l)
        }
        if (changed.length === 0) return

        const cmds = []
        if (changed.length > 1) {
            for (let i = 0; i < changed.length; i++) {
                const m = changed[i].mon
                cmds.push("hyprctl eval '" + monitorLua(m, { mode: monitorMode(m), position: parkX + "x0", scale: fixedScale(m) }) + "'")
                parkX += logicalWidth(m)
            }
        }
        for (let i = 0; i < layout.length; i++) {
            const l = layout[i]
            const m = l.mon
            const pos = l.x + "x" + l.y
            const mode = monitorMode(m)
            rememberMonitor(m, {
                mode: mode, scale: fixedScale(m), position: pos,
                extendedPosition: pos, disabled: false
            })
        }
        for (let i = 0; i < changed.length; i++) {
            const l = changed[i]
            const m = l.mon
            cmds.push("hyprctl eval '" + monitorLua(m, { mode: monitorMode(m), position: l.x + "x" + l.y, scale: fixedScale(m) }) + "'")
        }
        runShell(cmds)
    }

    // Rotate a monitor. Rotating changes its footprint, so monitors to its right or below
    // are shifted by the size difference to avoid overlap. Changed monitors are parked first.
    function setTransform(mon, t) {
        if (pShell.running || page.displayMode === "MIRRORED" || !mon || !mon.name || mon.disabled) return
        const cur = mon.transform || 0
        if (cur === t) return

        const dw = logicalWidthFor(mon, t) - logicalWidthFor(mon, cur)
        const dh = logicalHeightFor(mon, t) - logicalHeightFor(mon, cur)
        const oldRight = mon.x + logicalWidthFor(mon, cur)
        const oldBottom = mon.y + logicalHeightFor(mon, cur)

        const layout = page.activeMonitors.map(m => {
            const isTarget = m.name === mon.name
            return {
                mon: m,
                transform: isTarget ? t : (m.transform || 0),
                x: !isTarget && m.x >= oldRight ? m.x + dw : m.x,
                y: !isTarget && m.y >= oldBottom ? m.y + dh : m.y,
                force: isTarget
            }
        })

        const changed = layout.filter(l => l.force || l.x !== l.mon.x || l.y !== l.mon.y)

        const cmds = []
        if (changed.length > 1) {
            let parkX = 0
            for (let i = 0; i < layout.length; i++)
                parkX = Math.max(parkX, layout[i].x + logicalWidthFor(layout[i].mon, layout[i].transform))
            for (let i = 0; i < changed.length; i++) {
                const l = changed[i]
                cmds.push("hyprctl eval '" + monitorLua(l.mon, {
                    mode: monitorMode(l.mon), position: parkX + "x0",
                    scale: fixedScale(l.mon), transform: l.transform }) + "'")
                parkX += logicalWidthFor(l.mon, l.transform)
            }
        }

        for (let i = 0; i < layout.length; i++) {
            const l = layout[i]
            const pos = l.x + "x" + l.y
            rememberMonitor(l.mon, {
                mode: monitorMode(l.mon), scale: fixedScale(l.mon),
                position: pos, extendedPosition: pos,
                transform: l.transform, disabled: false })
        }
        for (let i = 0; i < changed.length; i++) {
            const l = changed[i]
            cmds.push("hyprctl eval '" + monitorLua(l.mon, {
                mode: monitorMode(l.mon), position: l.x + "x" + l.y,
                scale: fixedScale(l.mon), transform: l.transform }) + "'")
        }
        runShell(cmds)
    }

    function setMonitorEnabled(mon, enabled) {
        if (pShell.running || !mon || !mon.name) return
        let cmds = []
        if (enabled) {
            const entry = savedState[mon.name] || {}
            const mode = typeof entry.mode === "string" ? entry.mode : "preferred"
            const scale = scaleForMode(mode, mon, typeof entry.scale === "number" ? entry.scale : 1)
            // A disabled monitor may report transform 0, so restore the saved one.
            const transform = typeof entry.transform === "number" ? entry.transform : 0
            const savedExtended = parsePosition(entry.extendedPosition)
            const restoredPosition = page.displayMode === "MIRRORED"
                ? "0x0"
                : (savedExtended ? positionString(savedExtended.x, savedExtended.y) : "auto")
            const fields = {
                mode: mode, scale: scale, position: restoredPosition,
                transform: transform, disabled: false
            }
            if (savedExtended) fields.extendedPosition = positionString(savedExtended.x, savedExtended.y)
            rememberMonitor(mon, fields)
            // disabled: false is required. Without it Hyprland keeps the monitor disabled.
            cmds.push("hyprctl eval '" + monitorLua(mon, { mode: mode, position: restoredPosition, scale: scale, transform: transform, disabled: false }) + "'")
        } else {
            if (page.activeMonitors.length <= 1) return
            const atOrigin = mon.x === 0 && mon.y === 0
            const wasMain = page.effectiveMainName === mon.name
            const rest = page.activeMonitors.filter(m => m.name !== mon.name).sort((a, b) => a.x - b.x)
            const oldEntry = savedState[mon.name] || {}
            const extendedPosition = page.displayMode === "MIRRORED"
                ? oldEntry.extendedPosition
                : positionString(mon.x, mon.y)
            rememberMonitor(mon, {
                mode: monitorMode(mon), scale: fixedScale(mon),
                extendedPosition: extendedPosition, disabled: true
            })
            cmds.push("hyprctl eval '" + monitorLua(mon, { disabled: true }) + "'")
            // The disabled monitor can no longer be MAIN; hand it to the first remaining one.
            if (wasMain && rest.length > 0) {
                mainName = rest[0].name
                stateSaveTimer.restart()
            }
            // Only close the gap when the origin monitor disappears, as before.
            if (atOrigin) {
                cmds = cmds.concat(layoutCommands(rest))
            } else if (wasMain && rest.length > 0) {
                cmds.push("hyprctl dispatch focusmonitor '" + rest[0].name + "'")
            }
        }
        runShell(cmds)
    }

    Process {
        id: pList
        command: ["hyprctl", "monitors", "all", "-j"]
        running: true
        stdout: StdioCollector {
            onStreamFinished: {
                // Same output as last time: keep the existing model so the UI is not rebuilt.
                if (text === page.lastMonitorsJson) return
                try {
                    const parsed = JSON.parse(text)
                    page.lastMonitorsJson = text
                    page.monitors = parsed
                } catch (error) {
                    page.lastMonitorsJson = ""
                    page.monitors = []
                }
            }
        }
    }

    function refresh() {
        pList.running = true
    }

    Process {
        id: pApply
        property var pendingMon: null
        // Allows at most one retry with Hyprland's suggested scale, so a bad value can't loop.
        property bool retried: false

        stdout: StdioCollector {
            onStreamFinished: {
                const out = text.trim()
                if (out.length === 0) return

                const match = out.match(/using suggested scale:\s*([\d.]+)/i)
                if (match && pApply.pendingMon && !pApply.retried) {
                    const suggested = parseFloat(match[1])
                    page.setScale(pApply.pendingMon, suggested, true)
                }
            }
        }
        onExited: exitCode => {
            refreshTimer.restart()
        }
    }

    function gcd(a, b) { while (b) { [a, b] = [b, a % b] }; return a }

    // Nearest scale Hyprland accepts. Hyprland quantizes scale to multiples of 1/120
    // (the fractional-scale protocol unit) AND needs width/scale and height/scale to be
    // whole numbers. So a valid scale is n/120 where n divides gcd(w, h) * 120.
    // Integer arithmetic keeps the check exact (no float epsilon).
    function snapScale(w, h, requested) {
        if (!(w > 0) || !(h > 0) || !isFinite(requested) || requested <= 0) return requested
        const limit = gcd(w, h) * 120
        const target = requested * 120
        let bestN = 0
        let bestDistance = Infinity
        for (let n = 12; n <= 1200; n++) {
            if (limit % n !== 0) continue
            const d = Math.abs(n - target)
            if (d < bestDistance) { bestN = n; bestDistance = d }
        }
        return bestN > 0 ? bestN / 120 : requested
    }

    // Slider path: clamp to the slider range, then snap.
    function validScale(mon, requested) {
        return snapScale(mon.width, mon.height, Math.max(scaleMin, Math.min(scaleMax, requested)))
    }

    // Every scale Hyprland accepts for this mode, inside the slider range.
    function validScales(w, h) {
        const limit = gcd(w, h) * 120
        const list = []
        for (let n = Math.ceil(scaleMin * 120); n <= Math.floor(scaleMax * 120); n++)
            if (limit % n === 0) list.push(n / 120)
        return list
    }

    // Slider click -> nearest accepted scale. If that is the scale already applied,
    // step to the neighbouring accepted one in the direction of the click, so a click always moves.
    function pickScale(mon, requested) {
        const list = validScales(mon.width, mon.height)
        if (list.length === 0) return validScale(mon, requested)
        let best = 0
        for (let i = 1; i < list.length; i++)
            if (Math.abs(list[i] - requested) < Math.abs(list[best] - requested)) best = i
        if (Math.abs(list[best] - mon.scale) < 1e-6 && Math.abs(requested - mon.scale) > 1e-6) {
            const next = best + (requested > mon.scale ? 1 : -1)
            if (next >= 0 && next < list.length) best = next
        }
        return list[best]
    }

    function scaleToSlider(scale) {
        return Math.max(0, Math.min(1, (scale - scaleMin) / (scaleMax - scaleMin)))
    }

    // Any other path: snap against the dimensions of the mode that will actually be applied.
    function scaleForMode(mode, mon, scale) {
        const m = String(mode).match(/^(\d+)x(\d+)/)
        const w = m ? parseInt(m[1]) : (mon ? mon.width : 0)
        const h = m ? parseInt(m[2]) : (mon ? mon.height : 0)
        return snapScale(w, h, scale)
    }

    function fixedScale(mon) { return scaleForMode(monitorMode(mon), mon, mon.scale) }

    function setScale(mon, scale, isRetry = false) {
        if (pShell.running) return
        const applied = validScale(mon, scale)

        const idx = page.monitors.findIndex(m => m.name === mon.name)
        if (idx !== -1) {
            const updated = page.monitors.slice()
            updated[idx] = Object.assign({}, updated[idx], { scale: applied })
            // The model now differs from the last hyprctl output, so the next refresh must apply.
            page.lastMonitorsJson = ""
            page.monitors = updated
        }

        rememberMonitor(mon, { mode: monitorMode(mon), scale: applied, position: monitorPosition(mon) })

        pApply.pendingMon = mon
        pApply.retried = isRetry
        pApply.command = [
            "hyprctl", "eval",
            monitorLua(mon, { mode: monitorMode(mon), position: mon.x + "x" + mon.y, scale: applied })
        ]
        pApply.running = true
    }

    Process {
        id: pResolution
        onExited: exitCode => {
            refreshTimer.restart()
        }
    }

    function resolutionList(mon) {
        if (!mon || !mon.availableModes) return []
        const seen = {}
        const items = []
        for (let i = 0; i < mon.availableModes.length; i++) {
            const match = String(mon.availableModes[i]).match(/^(\d+)x(\d+)@/)
            if (!match) continue
            const key = match[1] + "x" + match[2]
            if (seen[key]) continue
            seen[key] = true
            items.push({ key: key, width: parseInt(match[1]), height: parseInt(match[2]) })
        }
        items.sort((a, b) => (b.width * b.height - a.width * a.height) || (b.width - a.width))
        return items.slice(0, 6).map(item => item.key)
    }

    function bestMode(mon, resolution) {
        if (!mon || !mon.availableModes) return null
        const prefix = resolution + "@"
        let bestRate = null
        let bestDistance = Infinity
        for (let i = 0; i < mon.availableModes.length; i++) {
            const mode = String(mon.availableModes[i])
            if (mode.indexOf(prefix) !== 0) continue
            const rate = parseFloat(mode.substring(prefix.length))
            if (isNaN(rate)) continue
            const distance = Math.abs(rate - mon.refreshRate)
            if (distance < bestDistance || (distance === bestDistance && rate > bestRate)) {
                bestRate = rate
                bestDistance = distance
            }
        }
        return bestRate === null ? null : prefix + bestRate.toFixed(2)
    }

    // Applies a mode (resolution + refresh rate) while keeping position and a valid scale.
    function applyMode(mon, mode) {
        if (pShell.running) return
        const scale = scaleForMode(mode, mon, mon.scale !== undefined ? mon.scale : 1)
        rememberMonitor(mon, { mode: mode, scale: scale, position: monitorPosition(mon) })
        pResolution.command = [
            "hyprctl", "eval",
            monitorLua(mon, { mode: mode, position: mon.x + "x" + mon.y, scale: scale })
        ]
        pResolution.running = true
    }

    function setResolution(mon, resolution) {
        if (!mon || !mon.name || !resolution) return
        applyMode(mon, resolution)
    }

    function refreshRates(mon) {
        if (!mon || !mon.availableModes) return []
        const prefix = mon.width + "x" + mon.height + "@"
        const seen = {}
        const rates = []
        for (let i = 0; i < mon.availableModes.length; i++) {
            const mode = String(mon.availableModes[i])
            if (mode.indexOf(prefix) !== 0) continue
            const match = mode.match(/@([\d.]+)/)
            if (!match) continue
            const rate = parseFloat(match[1])
            if (isNaN(rate)) continue
            const key = rate.toFixed(2)
            if (seen[key]) continue
            seen[key] = true
            rates.push(rate)
        }
        rates.sort((a, b) => b - a)
        return rates
    }

    function setRefreshRate(mon, rate) {
        if (!mon || !mon.name || rate === undefined) return
        applyMode(mon, mon.width + "x" + mon.height + "@" + rate.toFixed(2))
    }

    Timer { id: refreshTimer; interval: 250; onTriggered: page.refresh() }
    Timer { id: lateRefreshTimer; interval: 1500; onTriggered: page.refresh() }

    Flickable {
        id: flick
        anchors.fill: parent
        anchors.leftMargin: page.marginLeft; anchors.rightMargin: page.marginRight
        anchors.topMargin: page.marginTop; anchors.bottomMargin: page.marginBottom
        contentWidth: width
        contentHeight: content.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        ScrollBar.vertical: ScrollBar {
            background: Rectangle {
                color: "transparent"
                radius: width / 2
            }

            contentItem: Rectangle {
                color: "transparent"
                radius: width / 2
            }
        }

        Column {
            id: content
            width: flick.width
            spacing: 14

            Text {
                text: "DISPLAY"; color: Theme.text
                font.family: Theme.fontFamily; font.pixelSize: Theme.textSizeTitle; font.letterSpacing: 3
            }

            Rectangle { width: parent.width; height: 1; color: Theme.border }

            Column {
                width: parent.width; spacing: 8

                Row {
                    width: parent.width; spacing: 8

                    Text {
                        text: "LAYOUT"; color: Theme.textDim
                        font.family: Theme.fontFamily; font.pixelSize: Theme.textSizeBody
                        anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                        text: page.displayMode
                        color: page.displayMode === "MIRRORED" ? Theme.accent : Theme.textDim
                        font.family: Theme.fontFamily; font.pixelSize: Theme.textSizeBody; font.bold: true
                        anchors.verticalCenter: parent.verticalCenter
                    }
                }

                Row {
                    width: parent.width; spacing: 8

                    Rectangle {
                        width: (parent.width - parent.spacing) / 2; height: 34; radius: Theme.radius
                        color: page.displayMode === "EXTENDED" ? Theme.alpha(Theme.accent, 0.12) : (extendMouse.containsMouse ? Theme.alpha(Theme.accent, 0.08) : "#00000000")
                        border.width: 1
                        border.color: page.displayMode === "EXTENDED" || extendMouse.containsMouse ? Theme.accent : Theme.border

                        Text {
                            anchors.centerIn: parent; text: "EXTEND"; color: Theme.text
                            font.family: Theme.fontFamily; font.pixelSize: Theme.textSizeGroup; font.bold: true; font.letterSpacing: 1
                        }

                        MouseArea {
                            id: extendMouse
                            anchors.fill: parent; hoverEnabled: true
                            enabled: page.activeMonitors.length > 1 && !pShell.running
                            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: page.setDisplayMode("extend")
                        }
                    }

                    Rectangle {
                        width: (parent.width - parent.spacing) / 2; height: 34; radius: Theme.radius
                        color: page.displayMode === "MIRRORED" ? Theme.alpha(Theme.accent, 0.12) : (mirrorMouse.containsMouse ? Theme.alpha(Theme.accent, 0.08) : "#00000000")
                        border.width: 1
                        border.color: page.displayMode === "MIRRORED" || mirrorMouse.containsMouse ? Theme.accent : Theme.border

                        Text {
                            anchors.centerIn: parent; text: "MIRROR"; color: Theme.text
                            font.family: Theme.fontFamily; font.pixelSize: Theme.textSizeGroup; font.bold: true; font.letterSpacing: 1
                        }

                        MouseArea {
                            id: mirrorMouse
                            anchors.fill: parent; hoverEnabled: true
                            enabled: page.activeMonitors.length > 1 && !pShell.running
                            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                            onClicked: page.setDisplayMode("mirror")
                        }
                    }
                }
            }

            Column {
                width: parent.width; spacing: 8

                Repeater {
                    model: page.monitors

                    delegate: Rectangle {
                        id: card
                        required property var modelData
                        property bool off: modelData.disabled === true
                        property bool main: page.isMain(modelData)
                        // Position controls: the other active monitors and the one we place against.
                        property string refName: ""
                        readonly property var others: page.activeMonitors.filter(m => m.name !== modelData.name)
                        readonly property var refMon: others.find(m => m.name === refName) || others[0]
                        width: parent.width
                        height: cardColumn.implicitHeight + 20
                        radius: Theme.radius
                        color: "#00000000"; border.width: 1
                        border.color: modelData.focused && !off ? "#454545" : Theme.border

                        Column {
                            id: cardColumn
                            anchors.left: parent.left; anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.margins: 10
                            spacing: 6

                            Item {
                                width: parent.width; height: 24

                                Row {
                                    anchors.left: parent.left
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 8

                                    Text {
                                        text: card.modelData.name
                                        color: card.off ? Theme.textDim : Theme.text
                                        font.family: Theme.fontFamily; font.pixelSize: Theme.textSizeSection; font.bold: true
                                    }

                                    Text {
                                        visible: !card.off
                                        text: card.modelData.width + "x" + card.modelData.height + " @ " + Math.round(card.modelData.refreshRate) + "Hz"
                                        color: Theme.textDim; font.family: Theme.fontFamily; font.pixelSize: Theme.textSizeGroup
                                    }
                                }

                                Row {
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 6

                                    Rectangle {
                                        visible: !card.off && page.activeMonitors.length > 1
                                        width: 84; height: 24; radius: Theme.radius
                                        color: card.main ? Theme.alpha(Theme.accent, 0.10) : (mainMouse.containsMouse ? Theme.alpha(Theme.accent, 0.08) : "#00000000")
                                        border.width: 1
                                        border.color: card.main || mainMouse.containsMouse ? Theme.accent : Theme.border

                                        Text {
                                            anchors.centerIn: parent
                                            text: card.main ? "MAIN" : "SET MAIN"
                                            color: card.main ? Theme.accent : Theme.text
                                            font.family: Theme.fontFamily; font.pixelSize: Theme.textSizeBody; font.bold: true; font.letterSpacing: 1
                                        }

                                        MouseArea {
                                            id: mainMouse
                                            anchors.fill: parent; hoverEnabled: true
                                            enabled: !card.main
                                            cursorShape: card.main ? Qt.ArrowCursor : Qt.PointingHandCursor
                                            onClicked: page.setMainMonitor(card.modelData)
                                        }
                                    }

                                    Rectangle {
                                        visible: card.off || page.activeMonitors.length > 1
                                        width: 72; height: 24; radius: Theme.radius
                                        color: toggleMouse.containsMouse ? Theme.alpha(Theme.accent, 0.08) : "#00000000"
                                        border.width: 1
                                        border.color: toggleMouse.containsMouse ? Theme.accent : Theme.border

                                        Text {
                                            anchors.centerIn: parent
                                            text: card.off ? "ENABLE" : "DISABLE"
                                            color: Theme.text
                                            font.family: Theme.fontFamily; font.pixelSize: Theme.textSizeBody; font.bold: true; font.letterSpacing: 1
                                        }

                                        MouseArea {
                                            id: toggleMouse
                                            anchors.fill: parent; hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: page.setMonitorEnabled(card.modelData, card.off)
                                        }
                                    }
                                }
                            }

                            Row {
                                visible: !card.off
                                width: parent.width; spacing: 8

                                Text {
                                    width: 36; anchors.verticalCenter: parent.verticalCenter
                                    text: "SCALE"; color: Theme.textDim
                                    font.family: Theme.fontFamily; font.pixelSize: Theme.textSizeBody
                                }

                                Slider {
                                    id: scaleSlider
                                    width: parent.width - 36 - 44 - 16
                                    anchors.verticalCenter: parent.verticalCenter
                                    icon: "\uf00e"
                                    value: page.scaleToSlider(card.modelData.scale)
                                    onCommitted: v => {
                                        const target = page.pickScale(card.modelData,
                                            page.scaleMin + v * (page.scaleMax - page.scaleMin))
                                        page.setScale(card.modelData, target)
                                        // Interaction can break the binding above; restore it so the handle
                                        // jumps to the accepted scale instead of staying where you clicked.
                                        scaleSlider.value = Qt.binding(() => page.scaleToSlider(card.modelData.scale))
                                    }
                                }

                                Text {
                                    width: 44; anchors.verticalCenter: parent.verticalCenter
                                    horizontalAlignment: Text.AlignRight
                                    text: card.modelData.scale.toFixed(2) + "x"
                                    color: Theme.text
                                    font.family: Theme.fontFamily; font.pixelSize: Theme.textSizeBody
                                }
                            }

                            Row {
                                visible: !card.off
                                width: parent.width; spacing: 8
                                Text {
                                    width: 36; height: 28
                                    verticalAlignment: Text.AlignVCenter
                                    text: "RES"; color: Theme.textDim
                                    font.family: Theme.fontFamily; font.pixelSize: Theme.textSizeBody
                                }
                                Flow {
                                    width: parent.width - 36 - 8; spacing: 6
                                    Repeater {
                                        model: card.off ? [] : page.resolutionList(card.modelData)
                                        delegate: Rectangle {
                                            id: resButton
                                            required property string modelData
                                            property bool current: modelData === card.modelData.width + "x" + card.modelData.height
                                            width: 92; height: 28; radius: Theme.radius
                                            color: current ? Theme.alpha(Theme.accent, 0.10) : (resMouse.containsMouse ? Theme.alpha(Theme.accent, 0.08) : "#00000000")
                                            border.width: 1
                                            border.color: current || resMouse.containsMouse ? Theme.accent : Theme.border
                                            Text {
                                                anchors.centerIn: parent
                                                text: resButton.modelData
                                                color: Theme.text
                                                font.family: Theme.fontFamily; font.pixelSize: Theme.textSizeBody; font.bold: true
                                            }
                                            MouseArea {
                                                id: resMouse
                                                anchors.fill: parent; hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: {
                                                    const mode = page.bestMode(card.modelData, resButton.modelData)
                                                    if (mode) page.setResolution(card.modelData, mode)
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            Row {
                                visible: !card.off
                                width: parent.width; spacing: 8
                                Text {
                                    width: 36; height: 28
                                    verticalAlignment: Text.AlignVCenter
                                    text: "HZ"; color: Theme.textDim
                                    font.family: Theme.fontFamily; font.pixelSize: Theme.textSizeBody
                                }

                                Flow {
                                    width: parent.width - 36 - 8; spacing: 6
                                    Repeater {
                                        model: card.off ? [] : page.refreshRates(card.modelData)
                                        delegate: Rectangle {
                                            id: rateButton
                                            required property var modelData
                                            property bool current: Math.abs(modelData - card.modelData.refreshRate) < 0.05
                                            width: 76; height: 28; radius: Theme.radius
                                            color: current ? Theme.alpha(Theme.accent, 0.10) : (rateMouse.containsMouse ? Theme.alpha(Theme.accent, 0.08) : "#00000000")
                                            border.width: 1
                                            border.color: current || rateMouse.containsMouse ? Theme.accent : Theme.border
                                            Text {
                                                anchors.centerIn: parent
                                                text: rateButton.modelData.toFixed(2)
                                                color: Theme.text
                                                font.family: Theme.fontFamily; font.pixelSize: Theme.textSizeBody; font.bold: true
                                            }
                                            MouseArea {
                                                id: rateMouse
                                                anchors.fill: parent; hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: page.setRefreshRate(card.modelData, rateButton.modelData)
                                            }
                                        }
                                    }
                                }
                            }

                            // Rotation: 0 / 90 / 180 / 270 degrees (Hyprland transform 0-3).
                            Row {
                                visible: !card.off
                                width: parent.width; spacing: 8
                                Text {
                                    width: 36; height: 28
                                    verticalAlignment: Text.AlignVCenter
                                    text: "ROT"; color: Theme.textDim
                                    font.family: Theme.fontFamily; font.pixelSize: Theme.textSizeBody
                                }

                                Flow {
                                    width: parent.width - 36 - 8; spacing: 6
                                    Repeater {
                                        model: card.off ? [] : [
                                            { label: "0°", value: 0 },
                                            { label: "90°", value: 1 },
                                            { label: "180°", value: 2 },
                                            { label: "270°", value: 3 }
                                        ]
                                        delegate: Rectangle {
                                            id: rotButton
                                            required property var modelData
                                            property bool current: (card.modelData.transform || 0) === modelData.value
                                            width: 76; height: 28; radius: Theme.radius
                                            color: current ? Theme.alpha(Theme.accent, 0.10) : (rotMouse.containsMouse ? Theme.alpha(Theme.accent, 0.08) : "#00000000")
                                            border.width: 1
                                            border.color: current || rotMouse.containsMouse ? Theme.accent : Theme.border
                                            Text {
                                                anchors.centerIn: parent
                                                text: rotButton.modelData.label
                                                color: Theme.text
                                                font.family: Theme.fontFamily; font.pixelSize: Theme.textSizeBody; font.bold: true
                                            }
                                            MouseArea {
                                                id: rotMouse
                                                anchors.fill: parent; hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: page.setTransform(card.modelData, rotButton.modelData.value)
                                            }
                                        }
                                    }
                                }
                            }

                            // Which monitor to position against (only needed with 3+ active monitors).
                            Row {
                                visible: !card.off && card.others.length > 1
                                width: parent.width; spacing: 8
                                Text {
                                    width: 36; height: 28
                                    verticalAlignment: Text.AlignVCenter
                                    text: "OF"; color: Theme.textDim
                                    font.family: Theme.fontFamily; font.pixelSize: Theme.textSizeBody
                                }

                                Flow {
                                    width: parent.width - 36 - 8; spacing: 6
                                    Repeater {
                                        model: card.off ? [] : card.others.map(m => m.name)
                                        delegate: Rectangle {
                                            id: refButton
                                            required property string modelData
                                            property bool current: card.refMon !== undefined && card.refMon.name === modelData
                                            width: 92; height: 28; radius: Theme.radius
                                            color: current ? Theme.alpha(Theme.accent, 0.10) : (refMouse.containsMouse ? Theme.alpha(Theme.accent, 0.08) : "#00000000")
                                            border.width: 1
                                            border.color: current || refMouse.containsMouse ? Theme.accent : Theme.border
                                            Text {
                                                anchors.centerIn: parent
                                                text: refButton.modelData
                                                color: Theme.text
                                                font.family: Theme.fontFamily; font.pixelSize: Theme.textSizeBody; font.bold: true
                                            }
                                            MouseArea {
                                                id: refMouse
                                                anchors.fill: parent; hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: card.refName = refButton.modelData
                                            }
                                        }
                                    }
                                }
                            }

                            // Position controls: place this monitor left / right / above / below the reference.
                            Row {
                                visible: !card.off && card.others.length > 0
                                width: parent.width; spacing: 8
                                Text {
                                    width: 36; height: 28
                                    verticalAlignment: Text.AlignVCenter
                                    text: "POS"; color: Theme.textDim
                                    font.family: Theme.fontFamily; font.pixelSize: Theme.textSizeBody
                                }

                                Flow {
                                    width: parent.width - 36 - 8; spacing: 6
                                    Repeater {
                                        model: card.off ? [] : ["LEFT", "RIGHT", "ABOVE", "BELOW"]
                                        delegate: Rectangle {
                                            id: posButton
                                            required property string modelData
                                            property string side: modelData.toLowerCase()
                                            property bool current: card.refMon !== undefined && page.relation(card.modelData, card.refMon) === side
                                            width: 76; height: 28; radius: Theme.radius
                                            color: current ? Theme.alpha(Theme.accent, 0.10) : (posMouse.containsMouse ? Theme.alpha(Theme.accent, 0.08) : "#00000000")
                                            border.width: 1
                                            border.color: current || posMouse.containsMouse ? Theme.accent : Theme.border
                                            Text {
                                                anchors.centerIn: parent
                                                text: posButton.modelData
                                                color: Theme.text
                                                font.family: Theme.fontFamily; font.pixelSize: Theme.textSizeBody; font.bold: true
                                            }
                                            MouseArea {
                                                id: posMouse
                                                anchors.fill: parent; hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: page.placeMonitor(card.modelData, card.refMon, posButton.side)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }

            Rectangle {
                width: parent.width; height: 34; radius: Theme.radius
                color: resetMouse.containsMouse ? Theme.alpha(Theme.accent, 0.08) : "#00000000"
                border.width: 1
                border.color: resetMouse.containsMouse ? Theme.accent : Theme.border
                Text {
                    anchors.centerIn: parent; text: "RESET TO CONFIG"; color: Theme.text
                    font.family: Theme.fontFamily; font.pixelSize: Theme.textSizeGroup; font.bold: true; font.letterSpacing: 1
                }
                MouseArea {
                    id: resetMouse
                    anchors.fill: parent; hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: page.resetToConfig()
                }
            }
        }
    }

    Component.onCompleted: {
        stateDirProcess.running = true
        loadState()
    }
}
