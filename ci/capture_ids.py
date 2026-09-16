#!/usr/bin/env python3
"""Extract content message IDs from a Telegram API response.

For sendMediaGroup (array result): returns comma-separated IDs of all
content messages, skipping reply_to_message IDs (forum service messages).

For sendMessage/sendDocument (object result): returns the single message_id.
"""
import json, sys

d = json.load(sys.stdin)
r = d.get("result", [])
if isinstance(r, list):
    print(",".join(str(m["message_id"]) for m in r))
else:
    print(str(r["message_id"]))
