// Moni 动作「网页图片采集入 PS」的安装脚本：把 pscoke.jsx 复制到 Photoshop 的
// Presets/Scripts/Moni/<action-id>/ 目录。安装属于动作自己，Moni 只负责运行本脚本。
//
// job.params = { mode: "check" | "install", action_id, file_name }

function moniOwnFolder() {
  return new File($.fileName).parent;
}

function moniPresetScriptDirs() {
  var root = null;
  var home = $.getenv("HOME");
  var appData = $.getenv("APPDATA");
  if (appData) {
    root = new Folder(appData + "/Adobe");
  } else if (home) {
    root = new Folder(home + "/Library/Application Support/Adobe");
  }
  if (!root || !root.exists) { return []; }

  var dirs = [];
  var versions = root.getFiles();
  for (var i = 0; i < versions.length; i++) {
    var entry = versions[i];
    if (!(entry instanceof Folder)) { continue; }
    if (entry.name.indexOf("Adobe Photoshop") !== 0) { continue; }
    var scripts = new Folder(entry.fsName + "/Presets/Scripts");
    if (scripts.exists) { dirs.push(scripts); }
  }
  return dirs;
}

function moniRun(job) {
  var params = (job && job.params) || {};
  var mode = params.mode || "check";
  var actionId = params.action_id || "action";
  var fileName = params.file_name || "pscoke.jsx";
  var source = new File(moniOwnFolder().fsName + "/" + fileName);
  var dirs = moniPresetScriptDirs();
  var installed = [];

  for (var i = 0; i < dirs.length; i++) {
    var folder = new Folder(dirs[i].fsName + "/Moni/" + actionId);
    var target = new File(folder.fsName + "/" + fileName);
    if (mode === "install") {
      if (!source.exists) {
        throw { code: "A500_ACTION_FAILED", message: "missing source script: " + source.fsName };
      }
      if (!folder.exists && !folder.create()) {
        throw { code: "A500_ACTION_FAILED", message: "cannot create folder: " + folder.fsName };
      }
      if (target.exists && !target.remove()) {
        throw { code: "A500_ACTION_FAILED", message: "cannot replace: " + target.fsName };
      }
      if (!source.copy(target)) {
        throw { code: "A500_ACTION_FAILED", message: "cannot copy to: " + target.fsName };
      }
    }
    if (target.exists) { installed.push(target.fsName); }
  }

  return {
    installed: installed.length > 0,
    paths: installed,
    mode: mode
  };
}
