// Date helpers shared by the calendar and tasks pages.
// Dates from the worker are local "YYYY-MM-DDTHH:MM:SS" strings.
.pragma library

function pad(n) {
    return (n < 10 ? "0" : "") + n
}

// "YYYY-MM-DD"
function isoDay(d) {
    return d.getFullYear() + "-" + pad(d.getMonth() + 1) + "-" + pad(d.getDate())
}

// "YYYY-MM-DDTHH:MM"
function isoMinute(d) {
    return isoDay(d) + "T" + pad(d.getHours()) + ":" + pad(d.getMinutes())
}

function hhmm(d) {
    return pad(d.getHours()) + ":" + pad(d.getMinutes())
}

// Local date from "YYYY-MM-DD[THH:MM[:SS]]" (never through UTC)
function parse(text) {
    const m = /^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2})(?::(\d{2}))?)?/.exec(text || "")
    if (!m)
        return new Date(NaN)
    return new Date(+m[1], +m[2] - 1, +m[3], +(m[4] || 0), +(m[5] || 0), +(m[6] || 0))
}

// "terça-feira, 6 de outubro" -> "Terça-feira, 6 de outubro"
function capitalize(text) {
    return text ? text.charAt(0).toUpperCase() + text.slice(1) : text
}

function dayOnly(d) {
    return new Date(d.getFullYear(), d.getMonth(), d.getDate())
}

function addDays(d, n) {
    return new Date(d.getFullYear(), d.getMonth(), d.getDate() + n, d.getHours(), d.getMinutes())
}

function addMonths(d, n) {
    const target = new Date(d.getFullYear(), d.getMonth() + n, 1)
    const last = new Date(target.getFullYear(), target.getMonth() + 1, 0).getDate()
    return new Date(target.getFullYear(), target.getMonth(), Math.min(d.getDate(), last))
}

function sameDay(a, b) {
    return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate()
}

// JS weekday (0 = Sunday) the week starts on, from the locale
function firstWeekday(locale) {
    return locale.firstDayOfWeek % 7
}

function weekStart(d, locale) {
    const offset = (d.getDay() - firstWeekday(locale) + 7) % 7
    return addDays(dayOnly(d), -offset)
}

function monthGridStart(d, locale) {
    return weekStart(new Date(d.getFullYear(), d.getMonth(), 1), locale)
}

function minutesOfDay(d) {
    return d.getHours() * 60 + d.getMinutes()
}

// Calendar colour keys -> theme colours
function tone(key, theme) {
    switch (key) {
    case "green": return theme.greenColor
    case "orange": return theme.orangeColor
    case "red": return theme.redColor
    case "purple": return theme.purpleColor
    case "pink": return theme.pinkColor
    case "grey": return theme.greyColor
    default: return theme.blueColor
    }
}

var colorKeys = ["blue", "green", "orange", "red", "purple", "pink", "grey"]

// { "YYYY-MM-DD": [events] } — multi-day events appear on every day they cover
function byDay(events) {
    const map = {}
    for (let i = 0; i < events.length; ++i) {
        const e = events[i]
        const start = parse(e.start)
        let end = parse(e.end)
        // An end at midnight belongs to the previous day
        let last = dayOnly(end)
        if (end.getTime() > start.getTime() && minutesOfDay(end) === 0)
            last = addDays(last, -1)
        let day = dayOnly(start)
        let guard = 0
        while (day.getTime() <= last.getTime() && guard < 400) {
            const key = isoDay(day)
            if (!map[key])
                map[key] = []
            map[key].push(e)
            day = addDays(day, 1)
            ++guard
        }
    }
    for (const key in map) {
        map[key].sort(function (a, b) {
            if (a.allDay !== b.allDay)
                return a.allDay ? -1 : 1
            return a.start < b.start ? -1 : a.start > b.start ? 1 : 0
        })
    }
    return map
}

// Side-by-side columns for overlapping timed events of one day:
// [{ event, top (minutes), bottom (minutes), column, columns }]
function layoutDay(events, day) {
    const dayStart = dayOnly(day).getTime()
    const dayEnd = addDays(dayOnly(day), 1).getTime()
    const items = []
    for (let i = 0; i < events.length; ++i) {
        const e = events[i]
        if (e.allDay)
            continue
        const s = parse(e.start).getTime()
        const en = Math.max(parse(e.end).getTime(), s + 20 * 60000)
        if (en <= dayStart || s >= dayEnd)
            continue
        // A timed event over 24 h goes in the all-day strip
        if (parse(e.end).getTime() - s >= 24 * 3600000)
            continue
        items.push({ event: e, top: Math.max(0, (s - dayStart) / 60000),
                     bottom: Math.min(24 * 60, (en - dayStart) / 60000), column: 0, columns: 1 })
    }
    items.sort(function (a, b) { return a.top - b.top || b.bottom - a.bottom })
    let cluster = []
    let clusterEnd = -1
    function close() {
        let columns = 0
        for (let k = 0; k < cluster.length; ++k)
            columns = Math.max(columns, cluster[k].column + 1)
        for (let k = 0; k < cluster.length; ++k)
            cluster[k].columns = columns
        cluster = []
    }
    for (let i = 0; i < items.length; ++i) {
        const item = items[i]
        if (item.top >= clusterEnd && cluster.length)
            close()
        const used = []
        for (let k = 0; k < cluster.length; ++k)
            if (cluster[k].bottom > item.top)
                used.push(cluster[k].column)
        let col = 0
        while (used.indexOf(col) >= 0)
            ++col
        item.column = col
        cluster.push(item)
        clusterEnd = Math.max(clusterEnd, item.bottom)
    }
    if (cluster.length)
        close()
    return items
}

// Events shown in a week's all-day strip for a day: all-day ones and long timed ones
function longEvents(events) {
    const out = []
    for (let i = 0; i < events.length; ++i) {
        const e = events[i]
        if (e.allDay || parse(e.end).getTime() - parse(e.start).getTime() >= 24 * 3600000)
            out.push(e)
    }
    return out
}
