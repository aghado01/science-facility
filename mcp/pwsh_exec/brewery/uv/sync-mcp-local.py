"""Apply mcp.local.json's generic pwsh_exec block onto listed targets."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path


LOCAL_NAME = "mcp.local.json"
SCHEMA = "pwsh_exec/mcp-local/0.1"
SERVER = "pwsh_exec"
GENERIC_PROFILE_SUFFIX = "/scripts/pwsh/profile-pwsh.ps1"
LATEXAI_PROFILE_SUFFIX = "/scripts/profile.ps1"

_SERVER_TABLE = re.compile(
    r"(?ms)^\[mcp_servers\.pwsh_exec\][ \t]*\n(.*?)(?=^\[|\Z)"
)
_ENV_TABLE = re.compile(
    r"(?ms)^\[mcp_servers\.pwsh_exec\.env\][ \t]*\n(.*?)(?=^\[|\Z)"
)
def posix(path: Path) -> str:
    return path.expanduser().resolve().as_posix()


def relativize(path: Path, root: Path | None) -> str:
    resolved = path.expanduser().resolve()
    if root is None:
        return resolved.as_posix()
    try:
        rel = resolved.relative_to(root.expanduser().resolve()).as_posix()
    except ValueError:
        return resolved.as_posix()
    return "./" + rel


def _looks_like_path(value: str) -> bool:
    return "/" in value or "\\" in value


def registration_for_target(reg: dict, relative_to: Path | None) -> dict:
    args = [
        relativize(Path(item), relative_to) if _looks_like_path(item) else item
        for item in reg["args"]
    ]
    env = {
        key: relativize(Path(value), relative_to)
        for key, value in reg["env"].items()
    }
    return {
        "command": relativize(Path(reg["command"]), relative_to),
        "args": args,
        "env": env,
    }


def find_json_object(text: str, key: str) -> tuple[int, int]:
    pattern = re.compile(r'"%s"\s*:' % re.escape(key))
    for match in pattern.finditer(text):
        i = match.end()
        while i < len(text) and text[i] in " \t\r\n":
            i += 1
        if i >= len(text) or text[i] != "{":
            continue
        depth = 0
        in_str = False
        escape = False
        for pos, ch in enumerate(text[i:], i):
            if in_str:
                if escape:
                    escape = False
                elif ch == "\\":
                    escape = True
                elif ch == '"':
                    in_str = False
                continue
            if ch == '"':
                in_str = True
            elif ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth == 0:
                    return i, pos + 1
        raise ValueError(f"unclosed JSON object for {key!r}")
    raise ValueError(f"missing JSON object for {key!r}")


def _indent_of_line(text: str, pos: int) -> str:
    line_start = text.rfind("\n", 0, pos) + 1
    return re.match(r"[ \t]*", text[line_start:pos]).group(0)


def _dump_json_object(obj: dict, text: str, obj_start: int, obj_end: int) -> str:
    base = _indent_of_line(text, obj_start)
    inner = None
    for line in text[obj_start:obj_end].splitlines()[1:]:
        if line.strip():
            inner = len(re.match(r"[ \t]*", line).group(0))
            break
    step = 2 if inner is None else max(2, inner - len(base))
    dumped = json.dumps(obj, indent=step, ensure_ascii=False)
    return dumped.replace("\n", "\n" + base)


def apply_json(path: Path, block: dict) -> bool:
    text = path.read_text(encoding="utf-8")
    try:
        obj_start, obj_end = find_json_object(text, SERVER)
    except ValueError as exc:
        print(f"skip {path}: {exc}", file=sys.stderr)
        return False
    current = json.loads(text[obj_start:obj_end])
    if is_latexai_consumer(path, current.get("env") or {}):
        print(f"skip LaTeXAI consumer {path}", file=sys.stderr)
        return False
    merged = dict(current)
    merged["command"] = block["command"]
    merged["args"] = block["args"]
    env = dict(merged.get("env") or {})
    env.update(block["env"])
    merged["env"] = env
    dumped = _dump_json_object(merged, text, obj_start, obj_end)
    new_text = text[:obj_start] + dumped + text[obj_end:]
    if new_text == text:
        return False
    path.write_text(new_text, encoding="utf-8")
    return True


def apply_toml(path: Path, block: dict) -> bool:
    text = path.read_text(encoding="utf-8")
    env = _toml_env(text)
    if is_latexai_consumer(path, env):
        print(f"skip LaTeXAI consumer {path}", file=sys.stderr)
        return False
    command = block["command"]
    args = block["args"]
    args_literal = ",\n  ".join(json.dumps(item) for item in args)
    server_body = (
        f"command = {json.dumps(command)}\n"
        f"args = [\n  {args_literal},\n]\n"
    )
    env_body = "".join(
        f"{key} = {json.dumps(value)}\n" for key, value in block["env"].items()
    )
    if _SERVER_TABLE.search(text):
        text = _SERVER_TABLE.sub(
            lambda m: _rewrite_server_table(m.group(0), server_body),
            text,
            count=1,
        )
        if _ENV_TABLE.search(text):
            text = _upsert_toml_env(text, block["env"])
        else:
            text = text.rstrip() + "\n\n[mcp_servers.pwsh_exec.env]\n" + env_body
    else:
        text = (
            text.rstrip()
            + "\n\n[mcp_servers.pwsh_exec]\n"
            + server_body
            + "\n[mcp_servers.pwsh_exec.env]\n"
            + env_body
        )
    if not text.endswith("\n"):
        text += "\n"
    previous = path.read_text(encoding="utf-8")
    if text == previous:
        return False
    path.write_text(text, encoding="utf-8")
    return True


def _rewrite_server_table(table: str, server_body: str) -> str:
    header, _, rest = table.partition("\n")
    kept = []
    skip_args = False
    for line in rest.splitlines():
        stripped = line.strip()
        if skip_args:
            if stripped.startswith("]"):
                skip_args = False
            continue
        if stripped.startswith("command ="):
            continue
        if stripped.startswith("args ="):
            skip_args = "[" in stripped and "]" not in stripped
            continue
        kept.append(line)
    kept_text = "\n".join(kept).strip("\n")
    out = header + "\n" + server_body.rstrip() + "\n"
    if kept_text:
        out += kept_text + "\n"
    if not out.endswith("\n\n"):
        out += "\n"
    return out


def _toml_env(text: str) -> dict[str, str]:
    match = _ENV_TABLE.search(text)
    if not match:
        return {}
    env: dict[str, str] = {}
    for line in match.group(1).splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, _, raw = stripped.partition("=")
        env[key.strip()] = raw.strip().strip("\"'")
    return env


def _upsert_toml_env(text: str, env: dict) -> str:
    match = _ENV_TABLE.search(text)
    if not match:
        return text
    body = match.group(1)
    lines = list(body.splitlines())
    keys_seen: set[str] = set()
    new_lines = []
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            new_lines.append(line)
            continue
        key = stripped.split("=", 1)[0].strip()
        if key in env:
            new_lines.append(f"{key} = {json.dumps(env[key])}")
            keys_seen.add(key)
        else:
            new_lines.append(line)
    for key, value in env.items():
        if key not in keys_seen:
            new_lines.append(f"{key} = {json.dumps(value)}")
    while new_lines and not new_lines[-1].strip():
        new_lines.pop()
    replacement = "[mcp_servers.pwsh_exec.env]\n" + "\n".join(new_lines) + "\n"
    return text[: match.start()] + replacement + text[match.end() :]


def is_latexai_consumer(path: Path, env: dict) -> bool:
    profile = str(env.get("MCP_POWERSHELL_PROFILE") or "").replace("\\", "/")
    if profile.endswith(LATEXAI_PROFILE_SUFFIX) and not profile.endswith(
        GENERIC_PROFILE_SUFFIX
    ):
        return True
    if env.get("LATEXAI_ROOT"):
        return True
    return "LaTeXAI" in path.expanduser().resolve().parts


def discover_registration(project: Path) -> dict:
    registration_path = project / "deps" / "registrations" / "pwsh_exec.json"
    if registration_path.is_file():
        payload = json.loads(registration_path.read_text(encoding="utf-8"))
        return payload["mcpServers"]["pwsh_exec"]
    pythons = sorted((project / "deps" / "python").glob("cpython-*/python.exe"))
    if not pythons:
        raise SystemExit("no deps/registrations/pwsh_exec.json and no owned python")
    python = pythons[-1]
    return {
        "command": posix(python),
        "args": ["-B", posix(project / "server.py")],
        "env": {
            "MCP_POWERSHELL_EXECUTABLE": posix(
                project / "deps" / "bin" / "pwsh" / "pwsh.exe"
            ),
            "MCP_POWERSHELL_PROFILE": posix(
                project / "scripts" / "pwsh" / "profile-pwsh.ps1"
            ),
        },
    }


def seed_local(registration: dict) -> dict:
    return {
        "schema": SCHEMA,
        "registration": {
            "command": registration["command"],
            "args": list(registration["args"]),
            "env": dict(registration["env"]),
        },
        "targets": [],
    }


def load_local(path: Path) -> dict:
    local = json.loads(path.read_text(encoding="utf-8"))
    if local.get("schema") != SCHEMA:
        raise SystemExit(f"unsupported {LOCAL_NAME} schema")
    return local


def write_local(path: Path, local: dict) -> None:
    path.write_text(
        json.dumps(local, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )


def apply_targets(project: Path, local: dict) -> list[str]:
    updated: list[str] = []
    registration = local["registration"]
    for target in local.get("targets") or []:
        path = Path(target["path"]).expanduser()
        if not path.is_file():
            print(f"skip missing {path}", file=sys.stderr)
            continue
        relative_to = (
            Path(target["relativeTo"]).expanduser()
            if target.get("relativeTo")
            else None
        )
        block = registration_for_target(registration, relative_to)
        fmt = target["format"]
        if fmt == "mcp.json":
            changed = apply_json(path, block)
        elif fmt in {"grok.toml", "codex.toml"}:
            changed = apply_toml(path, block)
        else:
            raise SystemExit(f"unknown target format {fmt}")
        if changed:
            updated.append(str(path))
            print(path)
        else:
            print(f"unchanged {path}")
    return updated


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Sync generic pwsh_exec registration onto mcp.local.json targets."
    )
    parser.add_argument(
        "--refresh-registration",
        action="store_true",
        help="replace mcp.local.json registration from deps/registrations (seed if missing)",
    )
    args = parser.parse_args(argv)
    project = Path(__file__).resolve().parents[2]
    local_path = project / LOCAL_NAME
    if args.refresh_registration:
        registration = discover_registration(project)
        if local_path.is_file():
            local = load_local(local_path)
            local["registration"] = {
                "command": registration["command"],
                "args": list(registration["args"]),
                "env": dict(registration["env"]),
            }
        else:
            local = seed_local(registration)
        write_local(local_path, local)
    elif not local_path.is_file():
        raise SystemExit(
            f"missing {local_path}; run restore or copy targets into {LOCAL_NAME}"
        )
    else:
        local = load_local(local_path)
    apply_targets(project, local)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
