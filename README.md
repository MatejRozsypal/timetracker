# OE Time Log

Menu bar time study for Matt and Lukáš. Every finished block of work becomes an
event in a dedicated **OE Time log** Google Calendar, coded by client and activity
and coloured by focus (green, orange, red). Design and reasoning:
`reports/Time study app for founders.md` in the Second Brain.

## Install (each founder, on their own Mac)

1. Command Line Tools (Matt already has them): `xcode-select --install`
2. Get this folder (it is its own git repo, ignored by the Second Brain repo).
3. Build, install to /Applications and launch:

```bash
./build.sh
```

The app has no Dock icon. Look for the clock in the menu bar. On first launch it
registers itself as a login item and macOS asks to allow notifications: allow them.
Rebuild with the same command after any code change. Never AirDrop the built
`.app` to the other Mac: Gatekeeper blocks unsigned copies, so build on each Mac.

## Google setup (once, about 5 minutes)

Do this signed in as your **oneeighty.cz** account, not a personal Gmail.

1. https://console.cloud.google.com : create a project, e.g. `oe-timelog`. Check the
   project picker shows it under the **oneeighty.cz** organisation. If it does not,
   the next step will not offer Internal.
2. APIs and Services > Library: enable **Google Calendar API**.
3. Google Auth Platform > Branding / Audience: app name `OE Time Log`, user type
   **Internal**. Internal means no Google verification and no 7-day token expiry.
4. Data access: add the scope `https://www.googleapis.com/auth/calendar.app.created`
   (the app can only see calendars it created itself, nothing else in your calendar).
5. Clients > Create client > Application type **Desktop app**. Copy the client id
   and client secret.
6. Menu bar > Open data folder > edit `config.json`, paste both values into
   `googleClientId` and `googleClientSecret`, save, then click **Reload config**.
7. Click **Sign in with Google**. The browser opens, you approve, the tab says
   "connected". The app creates the **OE Time log** calendar on the first sync.

One OAuth client serves both founders: Lukáš pastes the same id and secret into his
own `config.json`. Then each of you shares your **OE Time log** calendar read-only
with the other (Google Calendar > settings for that calendar > Share with specific people).

## Daily use

Press **⌥⌘L** whenever you finish something. Type the block in one line:

```
client activity [+|-] note [g|o|r]
```

| Example | Meaning |
|---|---|
| `dob meta scaling test review g` | Dobias, Meta campaigns, green |
| `sales pipedrive follow-ups o` | First token is an activity, so client = `oe` |
| `man email + black friday draft` | `+`/`-` is the optional energy flag (audit weeks) |

Keys in the panel:

| Key | Does |
|---|---|
| Enter | Go to rating (or save straight away if you ended with g, o or r) |
| G / O / R | Save with that focus rating |
| Enter on an empty line | Repeat the last entry |
| Tab | Complete the suggested code |
| Cmd+1 to Cmd+8 | Insert a recent client + activity |
| Up / Down | Move the end time by 5 minutes |
| Shift+Up / Shift+Down | Move the start time by 5 minutes |
| Cmd+E | (After being away) include the away time, e.g. a call |
| Esc | Close (back to editing when rating) |

Focus rating, the same for both of us:

| | Rate it when |
|---|---|
| **G** green | Mostly single-tasking, did what I sat down to do at a normal pace |
| **O** orange | Got it done, but with switching, interruptions, or slower than it should be |
| **R** red | Mostly distracted, reactive or abandoned; the block produced little |

The start time is always the end of the previous entry, so you never type times.

### What prompts you

| Trigger | Behaviour |
|---|---|
| Hotkey | You decide. The main way to log |
| Back at the Mac after 10+ min locked, asleep or idle | Panel asks about the block **before you left**. Video calls hold off the idle trigger |
| 75 min of active time with no log | The menu bar icon shows a badge and the minutes. 15 min later a quiet banner you can reply to inline |
| 18:30 | Banner for the **day sweep**: every unlogged gap since you started, to log, mark **Off** (break) or **Unknown** |

Prompts only fire on workdays 08:00 to 20:00. The hotkey works any time.

## Config (`config.json`)

| Key | Default | |
|---|---|---|
| `hotkey` | `opt+cmd+L` | Modifiers `cmd opt ctrl shift`, then a letter, digit or `space` |
| `workDays` | `[2,3,4,5,6]` | 1 = Sunday ... 7 = Saturday |
| `workStart` / `workEnd` | `08:00` / `20:00` | Window for prompts |
| `awayMinutes` | `10` | Away threshold |
| `nudgeMinutes` | `75` | Active minutes before the icon nudges |
| `sweepTime` | `18:30` | Day sweep banner |
| `calendarName` | `OE Time log` | |

Click **Reload config** after editing. To change the client list or activity codes,
copy `Support/codebook.json` into the data folder and edit it there (it overrides the
built-in one). Keep the activity codes shared between the two of us so the data compares.

## Data

Everything lives in `~/Library/Application Support/OETimeLog/`:

| File | |
|---|---|
| `entries.jsonl` | Every entry, written before it is sent to Google. The local source of truth |
| `state.json` | Day start, last boundary, synced ids, calendar id |
| `token.json` | Google refresh token (file mode 0600, scope limited to the app's own calendar) |
| `config.json`, `codebook.json` | Settings |

Offline entries queue up and sync every 5 minutes, after every save, and on return to
the Mac. Each event id equals the local entry id, so a retry never creates a duplicate.
`Off` blocks never leave the Mac.

Calendar events carry the structured fields in `extendedProperties.private`
(`client`, `activity`, `bucket`, `rating`, `energy`, `trigger`), so the weekly
export does not have to parse titles.

## Develop

```bash
swift build -c release && .build/release/OETimeLog --selftest
```

`--render <dir>` draws the panel, menu and sweep views to PNGs offscreen.

## Not in v0.1 (see the report's v0.2 list)

- Meeting-end prompts (needs a read scope on the primary calendar)
- Editing a saved entry (for now: edit or delete the event in Google Calendar, the app does not read it back)
- Weekly export to a Sheet (Apps Script reading both shared calendars)
- Audit mode UI (the `+`/`-` energy flag already works in the title)
