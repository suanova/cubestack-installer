
class Ctx:
    def __init__(self):
        self.root = ""
        self.layout = ""
        self.level = ""
        self.failures = []
        self.warnings = []
        self.checks = {}
        self.files = []
        self.total_bytes = 0
        self.sizes_missing = False
        self.deep = False
        self.large_skipped = []
        self.missing_skipped = []
        self.deep_log_path = ""
        self.level_defaulted = False
        self.stamp_info = {"valid": False, "path": "", "reason": "not checked"}

def fail(ctx, path, kind, msg, expected=None, actual=None):
    item = {"path": path, "kind": kind, "message": msg}
    if expected is not None:
        item["expected"] = str(expected)
    if actual is not None:
        item["actual"] = str(actual)
    ctx.failures.append(item)

def warn(ctx, msg):
    ctx.warnings.append(msg)

def deep_log(ctx, msg):
    path = getattr(ctx, "deep_log_path", "")
    if not path:
        return
    try:
        with open(path, "a", encoding="utf-8") as f:
            f.write(msg + "\n")
    except OSError:
        pass

