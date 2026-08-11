#!/usr/bin/env bash
# Sample the playtest window's perf every 500ms and log it with a timestamp.
# Deliberately NOT in /tmp (it wipes).
OUT=/home/monteslu/code/cliemu/games-for-dad/eightball/.perflog/perf.jsonl
: > "$OUT"
while true; do
  TS=$(date +%s.%N)
  R=$(curl -s -X POST http://127.0.0.1:7331/tool/playtest \
        -H 'Content-Type: application/json' -H 'x-romdev-session: live' \
        -d '{"op":"status"}' 2>/dev/null)
  echo "{\"t\":$TS,\"r\":$R}" >> "$OUT"
  sleep 0.5
done
