/* Apple 产品分区对比 — 渲染与交互逻辑 */
(function () {
  "use strict";

  if (typeof ARC_DATA === "undefined") return;

  const CUTOFF = "2020-01"; // 只统计 2020-01 之后发布的机型
  const regions = ARC_DATA.regions;

  const iconFor = { yes: "fa-check", no: "fa-xmark", dep: "fa-circle-half-stroke" };

  /* ---------- 地区差异总览矩阵 ---------- */
  function renderMatrix() {
    const table = document.getElementById("regionMatrix");
    if (!table) return;
    const headRow = table.querySelector("thead tr");
    regions.forEach(function (r) {
      const th = document.createElement("th");
      th.innerHTML = '<span class="rg-flag">' + r.flag + "</span><span class=\"rg-label\">" + r.label + "</span>";
      headRow.appendChild(th);
    });

    const tbody = table.querySelector("tbody");
    ARC_DATA.matrix.forEach(function (row) {
      const tr = document.createElement("tr");
      const tdDim = document.createElement("td");
      tdDim.className = "sticky-col dim-cell";
      tdDim.innerHTML = '<span class="dim-name">' + row.dim + "</span>" +
        (row.note ? '<span class="dim-note">' + row.note + "</span>" : "");
      tr.appendChild(tdDim);

      regions.forEach(function (r) {
        const val = row.cells[r.key] || "no";
        const td = document.createElement("td");
        td.className = "cell cell-" + val;
        td.innerHTML = '<i class="fa-solid ' + iconFor[val] + '"></i>';
        td.title = r.label + " · " + row.dim;
        tr.appendChild(td);
      });
      tbody.appendChild(tr);
    });
  }

  /* ---------- 机型卡片 ---------- */
  function afterCutoff(released) {
    return (released || "") >= CUTOFF;
  }

  function regionLabel(key) {
    const r = regions.find(function (x) { return x.key === key; });
    return r ? r.flag + " " + r.label : key;
  }

  function buildProductCard(prod, catId) {
    const card = document.createElement("article");
    card.className = "arc-card";
    card.dataset.cat = catId;
    card.dataset.search = (prod.name + " " + prod.summary + " " +
      Object.keys(prod.regions).map(function (k) {
        const r = prod.regions[k];
        return regionLabel(k) + " " + (r.diffs || []).join(" ");
      }).join(" ")).toLowerCase();

    const head = document.createElement("button");
    head.className = "arc-card-head";
    head.type = "button";
    head.innerHTML =
      '<div class="arc-card-title">' +
        '<span class="arc-card-name">' + prod.name + "</span>" +
        '<span class="arc-card-date">发布：' + prod.released + "</span>" +
      "</div>" +
      '<i class="fa-solid fa-chevron-down arc-chevron"></i>';

    const body = document.createElement("div");
    body.className = "arc-card-body";

    let inner = '<p class="arc-card-summary">' + prod.summary + "</p>";
    inner += '<div class="arc-region-grid">';
    regions.forEach(function (r) {
      const info = prod.regions[r.key];
      if (!info) return;
      inner += '<div class="arc-region-block">' +
        '<div class="arc-region-head"><span class="rg-flag">' + r.flag + "</span>" +
        '<span class="rg-name">' + r.label + "</span>" +
        (info.model ? '<span class="rg-model">' + info.model + "</span>" : "") + "</div>" +
        '<ul class="arc-diff-list">' +
        (info.diffs || []).map(function (d) { return "<li>" + d + "</li>"; }).join("") +
        "</ul></div>";
    });
    inner += "</div>";
    body.innerHTML = inner;

    head.addEventListener("click", function () {
      const open = card.classList.toggle("open");
      body.style.maxHeight = open ? body.scrollHeight + "px" : "0px";
    });

    card.appendChild(head);
    card.appendChild(body);
    return card;
  }

  function renderProducts() {
    const list = document.getElementById("productList");
    if (!list) return;
    list.innerHTML = "";
    ARC_DATA.categories.forEach(function (cat) {
      cat.products.filter(function (p) { return afterCutoff(p.released); })
        .forEach(function (p) { list.appendChild(buildProductCard(p, cat.id)); });
    });
  }

  /* ---------- 功能知识库 ---------- */
  function renderFeatures() {
    const wrap = document.getElementById("featureList");
    if (!wrap) return;
    ARC_DATA.features.forEach(function (f) {
      const el = document.createElement("div");
      el.className = "arc-feature";
      el.innerHTML =
        '<div class="arc-feature-icon"><i class="' + f.icon + '"></i></div>' +
        '<div class="arc-feature-body">' +
          '<h3 class="arc-feature-title">' + f.title + "</h3>" +
          '<span class="arc-feature-by"><i class="fa-solid fa-sliders"></i> 取决于：' + f.by + "</span>" +
          '<p class="arc-feature-desc">' + f.desc + "</p>" +
        "</div>";
      wrap.appendChild(el);
    });
  }

  /* ---------- 过滤与搜索 ---------- */
  let activeCat = "all";
  let query = "";

  function applyFilter() {
    const cards = document.querySelectorAll("#productList .arc-card");
    let visible = 0;
    cards.forEach(function (card) {
      const matchCat = activeCat === "all" || card.dataset.cat === activeCat;
      const matchQuery = !query || card.dataset.search.indexOf(query) !== -1;
      const show = matchCat && matchQuery;
      card.style.display = show ? "" : "none";
      if (show) visible++;
    });
    const empty = document.getElementById("emptyState");
    if (empty) empty.hidden = visible !== 0;
  }

  function bindControls() {
    const seg = document.getElementById("catSeg");
    if (seg) {
      seg.addEventListener("click", function (e) {
        const btn = e.target.closest(".arc-seg-btn");
        if (!btn) return;
        seg.querySelectorAll(".arc-seg-btn").forEach(function (b) { b.classList.remove("active"); });
        btn.classList.add("active");
        activeCat = btn.dataset.cat;
        applyFilter();
      });
    }
    const search = document.getElementById("arcSearch");
    if (search) {
      search.addEventListener("input", function () {
        query = search.value.trim().toLowerCase();
        applyFilter();
      });
    }
  }

  /* ---------- init ---------- */
  function init() {
    renderMatrix();
    renderProducts();
    renderFeatures();
    bindControls();
    applyFilter();
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", init);
  } else {
    init();
  }
})();