#!/usr/bin/env python3
"""
Parse claude --output-format=stream-json --include-partial-messages output.

- stream_event/content_block_delta text_delta → log file (real-time, token by token)
- result event text → output file (for signal/rate-limit grep)
- rate_limit_event with non-allowed status → output file (triggers worker backoff)
- Non-JSON lines → log file always; output file only if not a partial JSON fragment
  (lines starting with '{' that fail to parse are likely truncated JSON from a crash
  and could contain false signal words like ALL_DONE inside a field value)

Usage: stream_parse.py <output_file> <log_file>
"""
import sys
import json


def main():
    if len(sys.argv) != 3:
        print("Usage: stream_parse.py <output_file> <log_file>", file=sys.stderr)
        sys.exit(1)

    output_path = sys.argv[1]
    log_path = sys.argv[2]

    try:
        out = open(output_path, "w")
        log = open(log_path, "a")
    except OSError as e:
        print(f"stream_parse: failed to open files: {e}", file=sys.stderr)
        sys.exit(1)

    try:
        for raw_line in sys.stdin:
            line = raw_line.rstrip("\n")
            if not line:
                continue

            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                # Non-JSON line: always write to log.
                log.write(line + "\n")
                log.flush()
                # Only write to output file if it's genuine text (mock claude,
                # error messages), NOT a partial JSON fragment from a crash.
                # Partial fragments start with '{' — they may contain signal
                # words like ALL_DONE inside field values, causing false positives.
                if not line.startswith("{"):
                    out.write(line + "\n")
                    out.flush()
                continue

            t = event.get("type", "")

            if t == "stream_event":
                inner = event.get("event", {})
                if inner.get("type") == "content_block_delta":
                    delta = inner.get("delta", {})
                    if delta.get("type") == "text_delta":
                        text = delta.get("text", "")
                        if text:
                            log.write(text)
                            log.flush()

            elif t == "result":
                result_text = event.get("result", "")
                out.write(result_text + "\n")
                out.flush()
                if event.get("is_error"):
                    log.write(f"\n[error] {result_text}\n")
                    log.flush()

            elif t == "rate_limit_event":
                rate_info = event.get("rate_limit_info", {})
                if rate_info.get("status") != "allowed":
                    resets_at = rate_info.get("resetsAt", "unknown")
                    msg = f"rate limit hit (resets {resets_at} UTC)\n"
                    out.write(msg)
                    out.flush()
    except OSError as e:
        print(f"stream_parse: I/O error during processing: {e}", file=sys.stderr)
        sys.exit(1)
    finally:
        out.close()
        log.close()


if __name__ == "__main__":
    main()
