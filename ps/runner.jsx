// Moni 动作自带的 Photoshop runner（ExtendScript / ES3）。
//
// 由动作通过 ctx.process.run 启动，不属于 Moni 宿主：
//   - Windows：Photoshop.exe -r runner.jsx，路径来自环境变量 MONI_JOB / MONI_SCRIPT / MONI_RESULT；
//   - macOS：osascript 的 do javascript 先设置 $.global.__MONI_*，再 $.evalFile 本文件。
//
// 流程：读 job.json → $.evalFile(MONI_SCRIPT) → 调用脚本的 moniRun(job) → 写 result.json。
// ExtendScript 没有 JSON，这里自带最小 parse/stringify。

function moniRunnerQuote(text) {
  var out = "\"";
  for (var i = 0; i < text.length; i++) {
    var ch = text.charAt(i);
    var code = text.charCodeAt(i);
    if (ch === "\"") {
      out += "\\\"";
    } else if (ch === "\\") {
      out += "\\\\";
    } else if (ch === "\n") {
      out += "\\n";
    } else if (ch === "\r") {
      out += "\\r";
    } else if (ch === "\t") {
      out += "\\t";
    } else if (code < 32 || code > 126) {
      var hex = code.toString(16);
      while (hex.length < 4) { hex = "0" + hex; }
      out += "\\u" + hex;
    } else {
      out += ch;
    }
  }
  return out + "\"";
}

function moniRunnerStringify(value) {
  if (value === null) { return "null"; }
  var type = typeof value;
  if (type === "number") { return isFinite(value) ? String(value) : "null"; }
  if (type === "boolean") { return value ? "true" : "false"; }
  if (type === "string") { return moniRunnerQuote(value); }
  if (type === "object") {
    var parts = [];
    var i;
    if (value instanceof Array) {
      for (i = 0; i < value.length; i++) {
        parts.push(moniRunnerStringify(value[i]));
      }
      return "[" + parts.join(",") + "]";
    }
    for (var key in value) {
      if (!value.hasOwnProperty(key)) { continue; }
      if (typeof value[key] === "undefined") { continue; }
      parts.push(moniRunnerQuote(key) + ":" + moniRunnerStringify(value[key]));
    }
    return "{" + parts.join(",") + "}";
  }
  return "null";
}

function moniRunnerParse(text) {
  var at = 0;

  function fail() {
    throw { code: "A500_ACTION_FAILED", message: "invalid job.json at offset " + at };
  }

  function skip() {
    while (at < text.length && " \t\r\n".indexOf(text.charAt(at)) >= 0) { at++; }
  }

  function parseString() {
    var out = "";
    at++;
    while (at < text.length) {
      var ch = text.charAt(at++);
      if (ch === "\"") { return out; }
      if (ch !== "\\") { out += ch; continue; }
      var esc = text.charAt(at++);
      if (esc === "\"") { out += "\""; }
      else if (esc === "\\") { out += "\\"; }
      else if (esc === "/") { out += "/"; }
      else if (esc === "b") { out += "\b"; }
      else if (esc === "f") { out += "\f"; }
      else if (esc === "n") { out += "\n"; }
      else if (esc === "r") { out += "\r"; }
      else if (esc === "t") { out += "\t"; }
      else if (esc === "u") {
        out += String.fromCharCode(parseInt(text.substr(at, 4), 16));
        at += 4;
      } else { fail(); }
    }
    fail();
  }

  function parseNumber() {
    var start = at;
    while (at < text.length && "-+.eE0123456789".indexOf(text.charAt(at)) >= 0) { at++; }
    var value = Number(text.substring(start, at));
    if (!isFinite(value)) { fail(); }
    return value;
  }

  function parseValue() {
    skip();
    var ch = text.charAt(at);
    if (ch === "{") {
      at++;
      var object = {};
      skip();
      if (text.charAt(at) === "}") { at++; return object; }
      while (at < text.length) {
        skip();
        if (text.charAt(at) !== "\"") { fail(); }
        var key = parseString();
        skip();
        if (text.charAt(at) !== ":") { fail(); }
        at++;
        object[key] = parseValue();
        skip();
        if (text.charAt(at) === ",") { at++; continue; }
        if (text.charAt(at) === "}") { at++; return object; }
        fail();
      }
      fail();
    }
    if (ch === "[") {
      at++;
      var array = [];
      skip();
      if (text.charAt(at) === "]") { at++; return array; }
      while (at < text.length) {
        array.push(parseValue());
        skip();
        if (text.charAt(at) === ",") { at++; continue; }
        if (text.charAt(at) === "]") { at++; return array; }
        fail();
      }
      fail();
    }
    if (ch === "\"") { return parseString(); }
    if (text.substr(at, 4) === "true") { at += 4; return true; }
    if (text.substr(at, 5) === "false") { at += 5; return false; }
    if (text.substr(at, 4) === "null") { at += 4; return null; }
    return parseNumber();
  }

  var value = parseValue();
  skip();
  if (at !== text.length) { fail(); }
  return value;
}

function moniRunnerRead(path) {
  var file = new File(path);
  if (!file.exists) {
    throw { code: "A500_ACTION_FAILED", message: "missing file: " + path };
  }
  file.encoding = "UTF-8";
  if (!file.open("r")) {
    throw { code: "A500_ACTION_FAILED", message: "cannot read: " + path };
  }
  var text = file.read();
  file.close();
  return text;
}

function moniRunnerWrite(path, text) {
  var file = new File(path);
  file.encoding = "UTF-8";
  if (!file.open("w")) {
    throw { code: "A500_ACTION_FAILED", message: "cannot write: " + path };
  }
  file.write(text);
  file.close();
}

function moniRunnerPath(envName, globalName) {
  if ($.global && $.global[globalName]) { return $.global[globalName]; }
  var value = $.getenv(envName);
  if (!value) {
    throw { code: "A500_ACTION_FAILED", message: "missing " + envName };
  }
  return value;
}

(function () {
  var resultPath = null;
  try {
    resultPath = moniRunnerPath("MONI_RESULT", "__MONI_RESULT");
    var jobPath = moniRunnerPath("MONI_JOB", "__MONI_JOB");
    var scriptPath = moniRunnerPath("MONI_SCRIPT", "__MONI_SCRIPT");
    var job = moniRunnerParse(moniRunnerRead(jobPath));
    $.evalFile(new File(scriptPath));
    var value = moniRun(job);
    moniRunnerWrite(resultPath, moniRunnerStringify({
      ok: true,
      value: typeof value === "undefined" ? null : value
    }));
  } catch (err) {
    var result = {
      ok: false,
      error: {
        code: (err && err.code) || "A500_ACTION_FAILED",
        message: (err && err.message) || String(err)
      }
    };
    if (err && err.line) { result.error.line = err.line; }
    if (resultPath) {
      try { moniRunnerWrite(resultPath, moniRunnerStringify(result)); } catch (ignored) {}
    }
  }
})();
