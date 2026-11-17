// Moni 动作「网页图片采集入 PS」的 Photoshop 脚本（ExtendScript / JSX）。
//
// 由动作自带的 runner 调用：moniRun(job)，job.params =
//   { assets:[{ path, name?, url? }], layout:"grid"|"layers",
//     columns, gap, fit:"contain"|"original", group, group_name, run_id }
//
// 每张图片以智能对象放入当前文档，按网格或整幅画布居中排布。

function moniClampInt(value, min, max) {
  var number = Math.round(Number(value));
  if (!isFinite(number)) { number = min; }
  if (number < min) { number = min; }
  if (number > max) { number = max; }
  return number;
}

function moniCanvasCell(width, height, gap) {
  var margin = Math.max(0, Number(gap) || 0);
  return {
    x: margin,
    y: margin,
    w: Math.max(1, width - margin * 2),
    h: Math.max(1, height - margin * 2)
  };
}

// 网格单元：cells.length === count，按列优先从左到右、从上到下。
function moniGridCells(count, width, height, columns, gap) {
  var total = Math.max(1, Math.floor(Number(count) || 1));
  var cols = moniClampInt(columns, 1, 8);
  var rows = Math.ceil(total / cols);
  var margin = Math.max(0, Number(gap) || 0);
  var cellWidth = (width - margin * (cols + 1)) / cols;
  var cellHeight = (height - margin * (rows + 1)) / rows;
  if (cellWidth < 1 || cellHeight < 1) {
    margin = 0;
    cellWidth = width / cols;
    cellHeight = height / rows;
  }

  var cells = [];
  for (var index = 0; index < total; index++) {
    var column = index % cols;
    var row = Math.floor(index / cols);
    cells.push({
      x: margin + column * (cellWidth + margin),
      y: margin + row * (cellHeight + margin),
      w: cellWidth,
      h: cellHeight
    });
  }
  return cells;
}

function moniLayerName(text, maxLength) {
  var name = String(text == null ? "" : text).replace(/\s+/g, " ").replace(/^\s+|\s+$/g, "");
  var limit = maxLength > 0 ? maxLength : 32;
  if (name.length > limit) {
    name = name.substring(0, limit - 1) + "\u2026";
  }
  return name.length ? name : "Image";
}

function moniLayerBounds(layer) {
  var bounds = layer.bounds;
  return {
    x: bounds[0].as("px"),
    y: bounds[1].as("px"),
    w: bounds[2].as("px") - bounds[0].as("px"),
    h: bounds[3].as("px") - bounds[1].as("px")
  };
}

function moniPlaceFile(path) {
  var descriptor = new ActionDescriptor();
  descriptor.putPath(charIDToTypeID("null"), new File(path));
  descriptor.putEnumerated(
    charIDToTypeID("FTcs"),
    charIDToTypeID("QCSt"),
    charIDToTypeID("Qcsa")
  );
  executeAction(charIDToTypeID("Plc "), descriptor, DialogModes.NO);
  return app.activeDocument.activeLayer;
}

function moniFitLayer(layer, cell, fit, warnings) {
  var bounds;
  try {
    bounds = moniLayerBounds(layer);
  } catch (error) {
    warnings.push("cannot read layer bounds: " + error.message);
    return;
  }
  if (bounds.w <= 0 || bounds.h <= 0) { return; }

  if (fit !== "original") {
    var scale = Math.min(cell.w / bounds.w, cell.h / bounds.h, 1);
    if (scale > 0 && Math.abs(scale - 1) > 0.01) {
      layer.resize(scale * 100, scale * 100, AnchorPosition.MIDDLECENTER);
      bounds = moniLayerBounds(layer);
    }
  }

  var dx = cell.x + (cell.w - bounds.w) / 2 - bounds.x;
  var dy = cell.y + (cell.h - bounds.h) / 2 - bounds.y;
  if (Math.abs(dx) > 0.5 || Math.abs(dy) > 0.5) {
    layer.translate(new UnitValue(dx, "px"), new UnitValue(dy, "px"));
  }
}

function moniRunApply() {
  var state = $.global.__moniJob;
  var params = state.params;
  var doc = state.doc;
  var warnings = state.warnings;
  var assets = params.assets || [];
  var width = doc.width.as("px");
  var height = doc.height.as("px");

  var cells;
  if (params.layout === "layers") {
    cells = [];
    var cell = moniCanvasCell(width, height, params.gap);
    for (var index = 0; index < assets.length; index++) {
      cells.push(cell);
    }
  } else {
    cells = moniGridCells(assets.length, width, height, params.columns, params.gap);
  }

  var group = null;
  if (params.group !== false) {
    try {
      group = doc.layerSets.add();
      group.name = params.group_name || "Moni Collect";
      doc.activeLayer = group;
    } catch (error) {
      warnings.push("cannot create layer group: " + error.message);
      group = null;
    }
  }

  var layers = [];
  for (var i = 0; i < assets.length; i++) {
    var asset = assets[i];
    try {
      var file = new File(asset.path);
      if (!file.exists) {
        warnings.push("missing file: " + asset.path);
        continue;
      }
      var layer = moniPlaceFile(asset.path);
      layer.name = moniLayerName(asset.name || file.name, 48);
      moniFitLayer(layer, cells[i], params.fit || "contain", warnings);
      if (group) { layer.move(group, ElementPlacement.INSIDE); }
      layers.push({ id: layer.id, name: layer.name });
    } catch (error) {
      warnings.push("asset " + (i + 1) + " failed: " + error.message);
    }
  }
  $.global.__moniResult = { layers: layers };
}

function moniRun(job) {
  if (!app.documents.length) {
    throw { code: "A401_PS_NO_DOC", message: "open a document before running this action" };
  }
  var params = (job && job.params) || {};
  if (!params.assets || !params.assets.length) {
    throw { code: "A404_NO_ELEMENTS", message: "no images to place" };
  }

  $.global.__moniJob = {
    doc: app.activeDocument,
    params: params,
    warnings: []
  };
  $.global.__moniResult = null;
  try {
    app.activeDocument.suspendHistory("Moni: collect images", "moniRunApply()");
    if (!$.global.__moniResult) {
      throw { code: "A500_ACTION_FAILED", message: "script did not finish" };
    }
    return {
      layers: $.global.__moniResult.layers,
      warnings: $.global.__moniJob.warnings
    };
  } finally {
    delete $.global.__moniJob;
    delete $.global.__moniResult;
  }
}
