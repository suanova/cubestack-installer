"""Zipapp / `python3 -m verifier` entry point."""
import sys

from .cli import main


def entry() -> "NoReturn":
    try:
        code = main()
    except BrokenPipeError:
        code = 1
    except Exception as exc:  # noqa: BLE001
        print(f"❌ 校验器内部错误: {exc}", file=sys.stderr)
        code = 2
    raise SystemExit(code)


if __name__ == "__main__":
    entry()
