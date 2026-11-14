# Session Journal

A World of Warcraft addon that writes a diary of every play session, so you can look back on what you did. It's especially fun for kids.

Each session gets a page with:

- **Big moments**: level-ups, dungeons entered and deaths, with times.
- **Places** you visited.
- **Quests** finished, with their rewards.
- **Monsters defeated**: total and top kills.
- **Loot**: item count, plus every green-or-better item (hover for its tooltip).
- **Skills** that went up, **gold** earned and spent, and **experience** gained.
- **Your own notes**, such as "Killed Hogger with Dad!", from the box under the page or with `/sj note ...`.

When you log in, you get a short hello: *"Welcome back! Last time (Thu 13 Nov, 1h 10m) you reached level 14, finished 6 quests and were last in Westfall."*

A `/reload` or relog within 15 minutes continues the same session. Empty sessions (under 2 minutes with nothing happening) are thrown away. The journal keeps the latest 300 sessions.

## Install

1. Download the zip (or **Code → Download ZIP** on GitHub) and extract it.
2. Rename the folder to `SessionJournal` if it's called `SessionJournal-main`.
3. Put it in `World of Warcraft\_forever_\Interface\AddOns\` so you have `AddOns\SessionJournal\SessionJournal.toc`.

## Commands

| Command | What it does |
|---|---|
| `/sj` or `/journal` | Open or close the journal |
| `/sj now` | How this session is going so far |
| `/sj note <text>` | Write a note on today's page |
| `/sj welcome` | The "last time you..." message on/off |

Data is saved per account in `SessionJournalDB` and never leaves your computer.

## Tests

`pip install lupa`, then run `python tests/test_sessionjournal.py`.
