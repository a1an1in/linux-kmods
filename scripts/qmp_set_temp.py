#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""通过 QMP 设置 QEMU 里 tmp105 的 temperature 属性（单位 m°C）。

用法：
    qmp_set_temp.py <qmp-unix-socket>            # 只找路径，打印到 stdout
    qmp_set_temp.py <qmp-unix-socket> <mC>       # 设置 temperature，并打印路径
    qmp_set_temp.py <qmp-unix-socket> get        # 读回 temperature（qom-get）

退出码：0 成功；2 没找到 tmp105 设备；1 连接/协议错误。

路径不写死（不同 QEMU/机器布局不同）：
  1) 先用 qom-list 广度优先遍历 QOM 树，命中条件 = 名字或类型含 tmp105
     且该节点确实有 temperature 属性（避免命中同名类型而 qom-set 报错）；
  2) 找不到再用 `info qom-tree` 的文本输出兜底 —— 注意 HMP 打印的是
     相对对象名（如 /device[10]），必须按缩进栈拼回完整路径。
"""
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


def _looks_like_tmp105(name, ntype):
    return "tmp105" in name or "tmp105" in ntype


def _not_found(msg):
    sys.stderr.write("%s\n" % msg)
    return 2


def find_via_qom_list(q):
    queue = [("", 0)]
    while queue:
        path, depth = queue.pop(0)
        for e in q.qom_list(path):
            name = e.get("name", "")
            ntype = e.get("type", "")
            child = (path.rstrip("/") + "/" + name) if path else ("/" + name)
            if _looks_like_tmp105(name, ntype) and q.has_prop(child, "temperature"):
                return child
            if ntype.startswith("child<") and depth < MAX_DEPTH:
                queue.append((child, depth + 1))
    return None


def find_via_qom_tree(q):
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
        if not _looks_like_tmp105(body, ""):
            continue
        path = "".join(n for _, n in stack)
        if not path.startswith("/"):
            path = "/" + path
        if q.has_prop(path, "temperature"):
            return path
    return None


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)

    q = Qmp(sys.argv[1])
    q.cmd({"execute": "qmp_capabilities"})

    path = find_via_qom_list(q) or find_via_qom_tree(q)
    if path is None:
        raise SystemExit(_not_found("没找到带 temperature 属性的 tmp105 设备"))

    if len(sys.argv) > 2:
        if sys.argv[2] == "get":
            val = q.cmd({"execute": "qom-get",
                         "arguments": {"path": path,
                                       "property": "temperature"}})
            print(val)
            return
        q.cmd({"execute": "qom-set",
               "arguments": {"path": path,
                             "property": "temperature",
                             "value": int(sys.argv[2])}})

    print(path)


main()
