#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""通用 QMP/QOM 小工具：定位 QEMU 里任意设备对象，读/写它的属性。

用法：
    qmp_dev.py <qmp-sock> find --match <子串> [--prop <属性>]
    qmp_dev.py <qmp-sock> get  --match <子串> [--prop <属性>]
    qmp_dev.py <qmp-sock> set  --match <子串> [--prop <属性>] --value <整数>
    qmp_dev.py <qmp-sock> hmp  <monitor 命令...>

  * `--match`：在 QOM 树里挑设备，匹配"对象名或类型名包含该子串"
    （例：`--match tmp105`、`--match emc1413`）。
  * `--prop`：要读/写的属性名，默认 `temperature`；也用来校验"该节点确实有这个属性"。
  * `hmp`：直接跑一条 QEMU monitor(HMP) 命令（不需要 --match），用来替代 Ctrl-A c。

退出码：0 成功；2 没找到匹配的设备；1 连接/协议错误。

实现要点（踩过的坑）：
  * QMP 第一行是 {"QMP": ...} 问候，必须跳过，否则响应会错位一帧；
  * `info qom-tree` 打印的是**相对对象名**（如 /device[10]），拼不出完整路径，
    所以主路径用 `qom-list` 广度优先遍历（结构化、可靠），HMP 只作兜底。
"""
import argparse
import json
import socket
import sys
import time

MAX_DEPTH = 12


def connect(path):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    for _ in range(50):
        try:
            s.connect(path)
            return s
        except OSError:
            time.sleep(0.2)
    raise SystemExit("QMP 连接失败：%s" % path)


class Qmp:
    def __init__(self, sock_path):
        self.f = connect(sock_path).makefile("rw")

    def cmd(self, obj):
        self.f.write(json.dumps(obj) + "\n")
        self.f.flush()
        while True:
            line = self.f.readline()
            if not line:
                raise SystemExit("QMP 连接断开")
            msg = json.loads(line)
            # 跳过 {"QMP": ...} 问候与 {"event": ...} 事件，只认响应
            if "return" in msg or "error" in msg:
                if "error" in msg:
                    raise SystemExit("QMP 错误：%s" % msg["error"])
                return msg["return"]

    def qom_list(self, path):
        try:
            entries = self.cmd({"execute": "qom-list",
                                "arguments": {"path": path}})
        except SystemExit:
            return []
        return entries if isinstance(entries, list) else []

    def has_prop(self, path, prop):
        return any(e.get("name") == prop for e in self.qom_list(path))


def _hit(match, name, ntype):
    return match in name or match in ntype


def find_via_qom_list(q, match, prop):
    queue = [("", 0)]
    while queue:
        path, depth = queue.pop(0)
        for e in q.qom_list(path):
            name = e.get("name", "")
            ntype = e.get("type", "")
            child = (path.rstrip("/") + "/" + name) if path else ("/" + name)
            if _hit(match, name, ntype) and (not prop or q.has_prop(child, prop)):
                return child
            if ntype.startswith("child<") and depth < MAX_DEPTH:
                queue.append((child, depth + 1))
    return None


def find_via_qom_tree(q, match, prop):
    """兜底：解析 `info qom-tree` 文本，按缩进栈拼完整路径。"""
    out = q.cmd({"execute": "human-monitor-command",
                 "arguments": {"command-line": "info qom-tree"}})
    if not isinstance(out, str):
        return None

    stack = []			# [(indent, name), ...]
    for line in out.splitlines():
        body = line.strip()
        if not body or body.startswith("->"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        name = body.split(" ")[0]
        while stack and stack[-1][0] >= indent:
            stack.pop()
        stack.append((indent, name))
        if not _hit(match, body, ""):
            continue
        path = "".join(n for _, n in stack)
        if not path.startswith("/"):
            path = "/" + path
        if not prop or q.has_prop(path, prop):
            return path
    return None


def parse_args():
    ap = argparse.ArgumentParser(
        description="QMP/QOM 小工具：定位设备、读写属性、执行 HMP 命令",
        usage="qmp_dev.py <qmp-sock> {find,get,set,hmp} [...]")
    ap.add_argument("sock", help="QMP unix socket 路径（QEMU -qmp unix:...）")
    ap.add_argument("action", choices=["find", "get", "set", "hmp"])
    ap.add_argument("--match", default="", help="设备名/类型匹配子串，如 tmp105")
    ap.add_argument("--prop", default="temperature", help="属性名（默认 temperature）")
    ap.add_argument("--value", type=int, help="set 要写入的整数值")
    ap.add_argument("hmpcmd", nargs="*", help="hmp 动作的命令（其他动作忽略）")
    return ap.parse_args()


def main():
    args = parse_args()
    q = Qmp(args.sock)
    q.cmd({"execute": "qmp_capabilities"})

    # 旁路：直接跑 monitor 命令，不需要匹配设备
    if args.action == "hmp":
        if not args.hmpcmd:
            raise SystemExit("hmp 需要命令，例如：hmp info status")
        out = q.cmd({"execute": "human-monitor-command",
                     "arguments": {"command-line": " ".join(args.hmpcmd)}})
        sys.stdout.write(out if isinstance(out, str) else json.dumps(out) + "\n")
        return

    if not args.match:
        raise SystemExit("find/get/set 都需要 --match <子串>")

    path = (find_via_qom_list(q, args.match, args.prop)
            or find_via_qom_tree(q, args.match, args.prop))
    if path is None:
        raise SystemExit(2)

    if args.action == "find":
        print(path)
        return

    if args.action == "get":
        print(q.cmd({"execute": "qom-get",
                     "arguments": {"path": path, "property": args.prop}}))
        return

    if args.value is None:
        raise SystemExit("set 需要 --value，例如："
                         "set --match tmp105 --prop temperature --value -6000")
    q.cmd({"execute": "qom-set",
           "arguments": {"path": path, "property": args.prop,
                         "value": args.value}})
    print(path)


main()
