// Moni 动作「网页图片采集入 PS」的安装脚本：把 pscoke.jsx 复制到 Photoshop 的
// Presets/Scripts/Moni/<action-id>/ 目录。安装属于动作自己，Moni 只负责运行本脚本。
//
// job.params = { mode: "check" | "install", action_id, file_name }

function moniOwnFolder() {
  return new File($.fileName).parent;
}

function moniPresetScriptDirs(createUser) {
  var dirs = [];
  var seen = {};
  function push(folder) {
    if (!folder || !folder.exists || seen[folder.fsName]) { return; }
    dirs.push(folder);
    seen[folder.fsName] = true;
  }
  // 便携版/精简安装的 Photoshop 把脚本目录放在程序目录下，先探测 app.path。
  try {
    push(new Folder(app.path + "/Presets/Scripts"));
  } catch (ignoredAppPath) {}

  var root = null;
  var home = $.getenv("HOME");
  var appData = $.getenv("APPDATA");
  if (appData) {
    root = new Folder(appData + "/Adobe");
  } else if (home) {
    root = new Folder(home + "/Library/Application Support/Adobe");
  }
  if (!root || !root.exists) { return dirs; }

  var versions = root.getFiles();
  for (var i = 0; i < versions.length; i++) {
    var entry = versions[i];
    if (!(entry instanceof Folder)) { continue; }
    if (entry.name.indexOf("Adobe Photoshop") !== 0) { continue; }
    var presets = new Folder(entry.fsName + "/Presets");
    var scripts = new Folder(presets.fsName + "/Scripts");
    // 用户目录可写，PS 启动时同样会扫描；需要时补建 Presets/Scripts。
    if (!scripts.exists && createUser) {
      if (presets.exists || presets.create()) { scripts.create(); }
    }
    push(scripts);
  }
  return dirs;
}

function moniRun(job) {
  var params = (job && job.params) || {};
  var mode = params.mode || "check";
  var actionId = params.action_id || "action";
  var fileName = params.file_name || "pscoke.jsx";
  var source = new File(moniOwnFolder().fsName + "/" + fileName);
  var dirs = moniPresetScriptDirs(mode === "install");
  var installed = [];
  var errors = [];

  for (var i = 0; i < dirs.length; i++) {
    var folder = new Folder(dirs[i].fsName + "/Moni/" + actionId);
    var target = new File(folder.fsName + "/" + fileName);
    if (mode === "install") {
      // 程序目录可能只读（管理员安装），失败不应连累用户目录，逐个尝试并汇总。
      try {
        if (!source.exists) {
          throw { message: "missing source script: " + source.fsName };
        }
        if (!folder.exists && !folder.create()) {
          throw { message: "cannot create folder: " + folder.fsName };
        }
        if (target.exists && !target.remove()) {
          throw { message: "cannot replace: " + target.fsName };
        }
        if (!source.copy(target)) {
          throw { message: "cannot copy to: " + target.fsName };
        }
      } catch (failure) {
        errors.push(String((failure && failure.message) || failure));
        continue;
      }
    }
    if (target.exists) { installed.push(target.fsName); }
  }

  if (mode === "install" && installed.length === 0) {
    throw {
      code: "A500_ACTION_FAILED",
      message: errors.length > 0 ? errors.join("; ") : "no writable Photoshop scripts folder"
    };
  }

  return {
    installed: installed.length > 0,
    paths: installed,
    mode: mode
  };
}
