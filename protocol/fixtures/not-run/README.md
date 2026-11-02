`task.finished` messages as runners send them (`wire`), and the `notRun` the server reads from each (`notRun`).
Older runners send `notRun` as plain strings: each reads as skipped after an earlier failure.
